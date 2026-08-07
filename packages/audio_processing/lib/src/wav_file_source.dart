import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'wav.dart';

/// A bounded-memory, file-backed WAV [AudioSource].
///
/// The source validates RIFF chunk boundaries during [prepare], then decodes
/// at most [chunkFrameCount] sample frames for each emitted [AudioFrame]. The
/// optional [start] and [duration] select a source-time window without loading
/// the complete file.
final class WavFileAudioSource implements AudioSource {
  /// Creates a WAV source for a Dart IO file.
  WavFileAudioSource({
    required this.path,
    required this.sourceId,
    this.trackId = 'audio',
    String? clockId,
    this.start = Duration.zero,
    this.duration,
    this.chunkFrameCount = 1600,
    this.maximumHeaderBytes = 1024 * 1024,
  }) : clockId = clockId ?? '$sourceId.timeline' {
    if (path.trim().isEmpty) {
      throw ArgumentError.value(path, 'path', 'Must not be empty.');
    }
    if (sourceId.trim().isEmpty ||
        trackId.trim().isEmpty ||
        this.clockId.trim().isEmpty) {
      throw ArgumentError('Audio source identifiers must not be empty.');
    }
    if (start.isNegative) {
      throw ArgumentError.value(start, 'start', 'Must not be negative.');
    }
    if (duration != null && duration!.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'Must not be negative.');
    }
    if (chunkFrameCount <= 0) {
      throw ArgumentError.value(
        chunkFrameCount,
        'chunkFrameCount',
        'Must be positive.',
      );
    }
    if (maximumHeaderBytes < 44) {
      throw ArgumentError.value(
        maximumHeaderBytes,
        'maximumHeaderBytes',
        'Must be at least 44 bytes.',
      );
    }
  }

  /// Source file path.
  final String path;

  /// Stable source ID assigned to emitted frames.
  final String sourceId;

  /// Stable logical track ID assigned to emitted frames.
  final String trackId;

  /// Stable monotonic clock ID assigned to emitted frames.
  final String clockId;

  /// Inclusive source-time start of the selected window.
  final Duration start;

  /// Maximum duration of the selected window, or the rest of the file.
  final Duration? duration;

  /// Maximum decoded sample frames held by any emitted frame.
  final int chunkFrameCount;

  /// Maximum byte offset at which audio data may begin.
  ///
  /// This bounds work spent traversing untrusted metadata chunks.
  final int maximumHeaderBytes;

  @override
  Future<WavFileAudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    RandomAccessFile? file;
    try {
      file = await File(path).open(mode: FileMode.read);
      cancellationToken?.throwIfCancelled();
      final _ParsedWavHeader header = await _parseWavHeader(
        file,
        maximumHeaderBytes: maximumHeaderBytes,
      );
      cancellationToken?.throwIfCancelled();
      final int firstFrame = header.format.framesForDuration(start);
      if (firstFrame > header.frameCount) {
        throw _InvalidWavFile(
          'The requested window starts after the end of the WAV file.',
        );
      }
      final int requestedEnd = duration == null
          ? header.frameCount
          : firstFrame + header.format.framesForDuration(duration!);
      final int endFrame = requestedEnd < header.frameCount
          ? requestedEnd
          : header.frameCount;
      return WavFileAudioSourceSession._(
        path: path,
        sourceId: sourceId,
        trackId: trackId,
        clockId: clockId,
        chunkFrameCount: chunkFrameCount,
        file: file,
        header: header,
        windowStartFrame: firstFrame,
        windowEndFrame: endFrame,
      );
    } on AudioCancelledException {
      if (file != null) {
        await file.close();
      }
      rethrow;
    } on _InvalidWavFile catch (error) {
      if (file != null) {
        await file.close();
      }
      throw AudioFailure(
        code: 'wav_file_invalid_header',
        stage: AudioFailureStage.preparation,
        message: error.message,
      );
    } catch (error, stackTrace) {
      if (file != null) {
        try {
          await file.close();
        } catch (_) {
          // Preserve the original preparation failure.
        }
      }
      Error.throwWithStackTrace(
        AudioFailure(
          code: 'wav_file_source_prepare_failed',
          stage: AudioFailureStage.preparation,
          message: 'The WAV source file could not be prepared.',
          safeCause: error.runtimeType.toString(),
        ),
        stackTrace,
      );
    }
  }
}

/// Prepared file-backed WAV source with pre-start random access.
final class WavFileAudioSourceSession implements AudioSourceSession {
  WavFileAudioSourceSession._({
    required this.path,
    required this.sourceId,
    required this.trackId,
    required this.clockId,
    required this.chunkFrameCount,
    required this._file,
    required this._header,
    required int windowStartFrame,
    required this._windowEndFrame,
  }) : _windowStartFrame = windowStartFrame,
       _currentFrame = windowStartFrame;

  /// Source file path.
  final String path;

  @override
  final String sourceId;

  @override
  final String trackId;

  @override
  final String clockId;

  /// Maximum sample frames decoded per emitted frame.
  final int chunkFrameCount;

  final RandomAccessFile _file;
  final _ParsedWavHeader _header;
  final int _windowStartFrame;
  final int _windowEndFrame;
  int _currentFrame;

  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>();
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _frames.stream,
    pauseSupported: true,
    onPause: _pauseForConsumer,
    onResume: _resumeForConsumer,
  );
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast();
  final Stopwatch _clock = Stopwatch();
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  Future<void>? _startFuture;
  Future<void>? _closeFuture;
  Completer<void>? _resumeGate;
  bool _explicitlyPaused = false;
  bool _consumerPaused = false;
  bool _stopRequested = false;
  bool _aborted = false;
  bool _fileClosed = false;

  /// Encoding stored in the WAV file.
  WavSampleEncoding get encoding => _header.encoding;

  /// Total sample frames in the source file, before windowing.
  int get sourceFrameCount => _header.frameCount;

  /// Effective start of the selected window, rounded to a sample frame.
  Duration get windowStart => format.durationForFrames(_windowStartFrame);

  /// Effective length of the selected window.
  Duration get windowDuration =>
      format.durationForFrames(_windowEndFrame - _windowStartFrame);

  /// Current absolute position on the source timeline.
  Duration get position => format.durationForFrames(_currentFrame);

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.pausable;

  @override
  AudioFormat get format => _header.format;

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses => Stream<AudioSessionStatus>.multi((
    MultiStreamController<AudioSessionStatus> controller,
  ) {
    controller.add(_status);
    final StreamSubscription<AudioSessionStatus> subscription = _statuses.stream
        .listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  /// Moves to an absolute source-time position before delivery starts.
  ///
  /// [sourcePosition] is rounded down to a sample frame and must remain inside
  /// the configured window (the end position is allowed). Seeking after
  /// [start] is deliberately rejected so frame order cannot change under a
  /// consumer.
  Future<void> seek(
    Duration sourcePosition, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (_status.state != AudioSessionState.prepared || _startFuture != null) {
      throw StateError('A WAV source can only seek before start.');
    }
    if (sourcePosition.isNegative) {
      throw ArgumentError.value(
        sourcePosition,
        'sourcePosition',
        'Must not be negative.',
      );
    }
    final int targetFrame = format.framesForDuration(sourcePosition);
    if (targetFrame < _windowStartFrame || targetFrame > _windowEndFrame) {
      throw RangeError.range(
        targetFrame,
        _windowStartFrame,
        _windowEndFrame,
        'sourcePosition',
        'Position must be inside the configured WAV window.',
      );
    }
    _currentFrame = targetFrame;
  }

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    return _startFuture ??= _start(cancellationToken);
  }

  Future<void> _start(AudioCancellationToken? cancellationToken) async {
    if (_status.state != AudioSessionState.prepared) {
      throw StateError('WAV audio can only start from prepared state.');
    }
    _clock.start();
    _transition(AudioSessionState.starting);
    if (cancellationToken != null) {
      unawaited(
        cancellationToken.whenCancelled.then((_) {
          final Completer<void>? gate = _resumeGate;
          if (gate != null && !gate.isCompleted) {
            gate.complete();
          }
        }),
      );
    }
    _transition(AudioSessionState.active);
    var sequence = 0;
    try {
      await _file.setPosition(
        _header.dataOffset + _currentFrame * _header.bytesPerFrame,
      );
      while (_currentFrame < _windowEndFrame && !_stopRequested && !_aborted) {
        cancellationToken?.throwIfCancelled();
        final Completer<void>? gate = _resumeGate;
        if (gate != null) {
          await gate.future;
          cancellationToken?.throwIfCancelled();
          if (_stopRequested || _aborted) {
            break;
          }
        }
        final int frameCount = _minimum(
          chunkFrameCount,
          _windowEndFrame - _currentFrame,
        );
        final int byteCount = frameCount * _header.bytesPerFrame;
        final Uint8List bytes = await _file.read(byteCount);
        if (bytes.length != byteCount) {
          throw const _InvalidWavFile(
            'The WAV data chunk ended before its declared length.',
          );
        }
        final int sampleOffset = _currentFrame;
        _frames.add(
          AudioFrame.owned(
            format: format,
            samples: _decodeSamples(bytes, _header.encoding),
            sourceId: sourceId,
            trackId: trackId,
            clockId: clockId,
            sequence: sequence,
            sampleOffset: sampleOffset,
            timestamp: format.durationForFrames(sampleOffset),
          ),
        );
        _currentFrame += frameCount;
        sequence += 1;
        await Future<void>.delayed(Duration.zero);
      }
      _requestFrameClose();
      if (!_aborted) {
        _transition(AudioSessionState.finished);
      }
    } on AudioCancelledException catch (error) {
      await abort(
        failure: AudioFailure(
          code: 'wav_file_source_cancelled',
          stage: AudioFailureStage.processing,
          message: 'WAV frame delivery was cancelled.',
          safeCause: error.runtimeType.toString(),
        ),
      );
      rethrow;
    } catch (error, stackTrace) {
      final AudioFailure failure = AudioFailure(
        code: error is _InvalidWavFile
            ? 'wav_file_invalid_data'
            : 'wav_file_source_read_failed',
        stage: AudioFailureStage.processing,
        message: error is _InvalidWavFile
            ? error.message
            : 'The WAV source file could not be read.',
        safeCause: error.runtimeType.toString(),
      );
      if (!_frames.isClosed) {
        _frames.addError(failure, stackTrace);
      }
      await abort(failure: failure);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_explicitlyPaused) {
      return;
    }
    if (_status.state != AudioSessionState.active &&
        _status.state != AudioSessionState.paused) {
      throw StateError('Only active WAV audio can be paused.');
    }
    _explicitlyPaused = true;
    _updatePauseState();
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (!_explicitlyPaused) {
      return;
    }
    _explicitlyPaused = false;
    _updatePauseState();
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_status.isTerminal) {
      return;
    }
    _stopRequested = true;
    _releasePause();
    await _awaitStartIgnoringFailure();
    if (_startFuture == null) {
      _requestFrameClose();
      _transition(AudioSessionState.finished);
    }
    cancellationToken?.throwIfCancelled();
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (_aborted || _status.state == AudioSessionState.closed) {
      return;
    }
    _aborted = true;
    _stopRequested = true;
    _releasePause();
    _requestFrameClose();
    _transition(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (!_status.isTerminal) {
      await abort();
    }
    await _awaitStartIgnoringFailure();
    _requestFrameClose();
    if (!_fileClosed) {
      _fileClosed = true;
      await _file.close();
    }
    _transition(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
    _clock.stop();
  }

  Future<void> _awaitStartIgnoringFailure() async {
    try {
      await _startFuture;
    } catch (_) {
      // The caller of start observes the original failure.
    }
  }

  void _pauseForConsumer() {
    if (_consumerPaused ||
        (_status.state != AudioSessionState.active &&
            _status.state != AudioSessionState.paused)) {
      return;
    }
    _consumerPaused = true;
    _updatePauseState();
  }

  void _resumeForConsumer() {
    if (!_consumerPaused) {
      return;
    }
    _consumerPaused = false;
    _updatePauseState();
  }

  void _updatePauseState() {
    if (_explicitlyPaused || _consumerPaused) {
      _resumeGate ??= Completer<void>();
      if (_status.state == AudioSessionState.active) {
        _transition(AudioSessionState.paused);
      }
      return;
    }
    final Completer<void>? gate = _resumeGate;
    _resumeGate = null;
    if (_status.state == AudioSessionState.paused) {
      _transition(AudioSessionState.active);
    }
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  void _releasePause() {
    _explicitlyPaused = false;
    _consumerPaused = false;
    final Completer<void>? gate = _resumeGate;
    _resumeGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  void _requestFrameClose() {
    if (!_frames.isClosed) {
      unawaited(_frames.close());
    }
  }

  void _transition(AudioSessionState state, {AudioFailure? failure}) {
    _status = AudioSessionStatus(
      state: state,
      timestamp: _clock.elapsed,
      failure: failure,
    );
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }
}

final class _ParsedWavHeader {
  const _ParsedWavHeader({
    required this.format,
    required this.encoding,
    required this.dataOffset,
    required this.dataLength,
    required this.bytesPerFrame,
  });

  final AudioFormat format;
  final WavSampleEncoding encoding;
  final int dataOffset;
  final int dataLength;
  final int bytesPerFrame;

  int get frameCount => dataLength ~/ bytesPerFrame;
}

Future<_ParsedWavHeader> _parseWavHeader(
  RandomAccessFile file, {
  required int maximumHeaderBytes,
}) async {
  final int fileLength = await file.length();
  if (fileLength < 12) {
    throw const _InvalidWavFile('The WAV file is shorter than a RIFF header.');
  }
  await file.setPosition(0);
  final Uint8List riffBytes = await file.read(12);
  if (riffBytes.length != 12) {
    throw const _InvalidWavFile('The WAV RIFF header is truncated.');
  }
  final ByteData riff = ByteData.sublistView(riffBytes);
  if (_ascii(riff, 0, 4) != 'RIFF' || _ascii(riff, 8, 4) != 'WAVE') {
    throw const _InvalidWavFile('The file is not a RIFF/WAVE stream.');
  }
  final int riffEnd = 8 + riff.getUint32(4, Endian.little);
  if (riffEnd < 12 || riffEnd > fileLength) {
    throw const _InvalidWavFile('The declared RIFF payload is truncated.');
  }

  _ParsedWavFormat? parsedFormat;
  var chunkOffset = 12;
  while (chunkOffset + 8 <= riffEnd) {
    if (chunkOffset + 8 > maximumHeaderBytes) {
      throw const _InvalidWavFile(
        'The WAV header exceeds the configured scan limit.',
      );
    }
    await file.setPosition(chunkOffset);
    final Uint8List chunkBytes = await file.read(8);
    if (chunkBytes.length != 8) {
      throw const _InvalidWavFile('A WAV chunk header is truncated.');
    }
    final ByteData chunk = ByteData.sublistView(chunkBytes);
    final String chunkId = _ascii(chunk, 0, 4);
    final int chunkLength = chunk.getUint32(4, Endian.little);
    final int dataOffset = chunkOffset + 8;
    final int dataEnd = dataOffset + chunkLength;
    final int paddedEnd = dataEnd + (chunkLength.isOdd ? 1 : 0);
    if (dataEnd > riffEnd || paddedEnd > riffEnd) {
      throw const _InvalidWavFile('A WAV chunk exceeds the RIFF boundary.');
    }

    if (chunkId == 'fmt ') {
      if (parsedFormat != null) {
        throw const _InvalidWavFile('The WAV file has multiple fmt chunks.');
      }
      if (chunkLength < 16) {
        throw const _InvalidWavFile('The WAV fmt chunk is too short.');
      }
      await file.setPosition(dataOffset);
      final Uint8List formatBytes = await file.read(16);
      if (formatBytes.length != 16) {
        throw const _InvalidWavFile('The WAV fmt chunk is truncated.');
      }
      parsedFormat = _parseFormat(ByteData.sublistView(formatBytes));
    } else if (chunkId == 'data') {
      final _ParsedWavFormat? format = parsedFormat;
      if (format == null) {
        throw const _InvalidWavFile(
          'The WAV fmt chunk must appear before the data chunk.',
        );
      }
      if (dataOffset > maximumHeaderBytes) {
        throw const _InvalidWavFile(
          'The WAV header exceeds the configured scan limit.',
        );
      }
      if (chunkLength % format.bytesPerFrame != 0) {
        throw const _InvalidWavFile(
          'The WAV data length is not aligned to a sample frame.',
        );
      }
      return _ParsedWavHeader(
        format: AudioFormat(
          sampleRate: format.sampleRate,
          channels: format.channels,
        ),
        encoding: format.encoding,
        dataOffset: dataOffset,
        dataLength: chunkLength,
        bytesPerFrame: format.bytesPerFrame,
      );
    }
    chunkOffset = paddedEnd;
  }
  throw const _InvalidWavFile('The WAV file has no audio data chunk.');
}

final class _ParsedWavFormat {
  const _ParsedWavFormat({
    required this.encoding,
    required this.channels,
    required this.sampleRate,
    required this.bytesPerFrame,
  });

  final WavSampleEncoding encoding;
  final int channels;
  final int sampleRate;
  final int bytesPerFrame;
}

_ParsedWavFormat _parseFormat(ByteData data) {
  final int formatCode = data.getUint16(0, Endian.little);
  final int channels = data.getUint16(2, Endian.little);
  final int sampleRate = data.getUint32(4, Endian.little);
  final int byteRate = data.getUint32(8, Endian.little);
  final int blockAlign = data.getUint16(12, Endian.little);
  final int bitsPerSample = data.getUint16(14, Endian.little);
  final WavSampleEncoding encoding = switch ((formatCode, bitsPerSample)) {
    (1, 16) => WavSampleEncoding.pcm16,
    (3, 32) => WavSampleEncoding.float32,
    _ => throw _InvalidWavFile(
      'Unsupported WAV encoding (format $formatCode, $bitsPerSample bits).',
    ),
  };
  if (channels <= 0 || sampleRate <= 0) {
    throw const _InvalidWavFile(
      'The WAV channel count and sample rate must be positive.',
    );
  }
  final int expectedBlockAlign = channels * encoding.bytesPerSample;
  if (blockAlign != expectedBlockAlign ||
      byteRate != sampleRate * expectedBlockAlign) {
    throw const _InvalidWavFile(
      'The WAV byte rate or block alignment is inconsistent.',
    );
  }
  return _ParsedWavFormat(
    encoding: encoding,
    channels: channels,
    sampleRate: sampleRate,
    bytesPerFrame: expectedBlockAlign,
  );
}

Float32List _decodeSamples(Uint8List bytes, WavSampleEncoding encoding) {
  final ByteData data = ByteData.sublistView(bytes);
  final Float32List samples = Float32List(
    bytes.length ~/ encoding.bytesPerSample,
  );
  switch (encoding) {
    case WavSampleEncoding.pcm16:
      for (var index = 0; index < samples.length; index += 1) {
        samples[index] = data.getInt16(index * 2, Endian.little) / 32768;
      }
    case WavSampleEncoding.float32:
      for (var index = 0; index < samples.length; index += 1) {
        samples[index] = data.getFloat32(index * 4, Endian.little);
      }
  }
  return samples;
}

final class _InvalidWavFile implements Exception {
  const _InvalidWavFile(this.message);

  final String message;
}

String _ascii(ByteData data, int offset, int length) => String.fromCharCodes(
  List<int>.generate(length, (int index) => data.getUint8(offset + index)),
);

int _minimum(int left, int right) => left < right ? left : right;
