import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'processor.dart';
import 'wav.dart';

/// What a file-backed WAV sink does with accepted audio after an abort.
enum WavFileAbortPolicy {
  /// Remove the incomplete recording.
  deletePartial,

  /// Write a valid header for all sample bytes already accepted.
  finalizeAcceptedAudio,
}

/// A single-use, bounded-memory WAV [AudioSink] backed by a local file.
///
/// [prepare] creates or truncates [path] and writes a placeholder canonical
/// WAV header. Every `write` encodes directly to the file in bounded chunks;
/// callers must honor [AudioSinkCapabilities.requiresSequentialWrites].
final class WavFileAudioSink implements AudioSink {
  /// Creates a file-backed sink.
  WavFileAudioSink({
    required this.path,
    this.encoding = WavSampleEncoding.pcm16,
    this.gapPolicy = WavGapPolicy.reject,
    this.abortPolicy = WavFileAbortPolicy.finalizeAcceptedAudio,
    this.encodingBufferBytes = 64 * 1024,
  }) {
    if (path.trim().isEmpty) {
      throw ArgumentError.value(path, 'path', 'Must not be empty.');
    }
    if (encodingBufferBytes <= 0) {
      throw ArgumentError.value(
        encodingBufferBytes,
        'encodingBufferBytes',
        'Must be positive.',
      );
    }
  }

  /// Destination file path.
  final String path;

  /// PCM representation stored in the WAV data chunk.
  final WavSampleEncoding encoding;

  /// How source timeline gaps are handled.
  final WavGapPolicy gapPolicy;

  /// Cleanup behavior for an aborted or failed session.
  final WavFileAbortPolicy abortPolicy;

  /// Maximum temporary encoding allocation per file write.
  final int encodingBufferBytes;

  bool _prepared = false;

  @override
  Future<WavFileAudioSinkSession> prepare(
    AudioFormat format, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final int bytesPerFrame = format.channels * encoding.bytesPerSample;
    if (encodingBufferBytes < bytesPerFrame) {
      throw ArgumentError.value(
        encodingBufferBytes,
        'encodingBufferBytes',
        'Must hold at least one encoded interleaved sample frame '
            '($bytesPerFrame bytes).',
      );
    }
    if (_prepared) {
      throw StateError('A WavFileAudioSink is single-use.');
    }
    _prepared = true;
    return WavFileAudioSinkSession._prepare(
      path: path,
      format: format,
      encoding: encoding,
      gapPolicy: gapPolicy,
      abortPolicy: abortPolicy,
      encodingBufferBytes: encodingBufferBytes,
      cancellationToken: cancellationToken,
    );
  }
}

/// Prepared file-backed WAV recording session.
final class WavFileAudioSinkSession implements AudioSinkSession {
  WavFileAudioSinkSession._({
    required this.path,
    required this.format,
    required this.encoding,
    required this.gapPolicy,
    required this.abortPolicy,
    required this.encodingBufferBytes,
    required this._file,
  }) {
    _clock.start();
  }

  static Future<WavFileAudioSinkSession> _prepare({
    required String path,
    required AudioFormat format,
    required WavSampleEncoding encoding,
    required WavGapPolicy gapPolicy,
    required WavFileAbortPolicy abortPolicy,
    required int encodingBufferBytes,
    required AudioCancellationToken? cancellationToken,
  }) async {
    RandomAccessFile? file;
    try {
      cancellationToken?.throwIfCancelled();
      file = await File(path).open(mode: FileMode.write);
      cancellationToken?.throwIfCancelled();
      await file.writeFrom(
        _wavHeader(format: format, encoding: encoding, dataLength: 0),
      );
      cancellationToken?.throwIfCancelled();
      return WavFileAudioSinkSession._(
        path: path,
        format: format,
        encoding: encoding,
        gapPolicy: gapPolicy,
        abortPolicy: abortPolicy,
        encodingBufferBytes: encodingBufferBytes,
        file: file,
      );
    } on AudioCancelledException {
      if (file != null) {
        await file.close();
      }
      await _deleteIfPresent(path);
      rethrow;
    } catch (error) {
      if (file != null) {
        try {
          await file.close();
        } catch (_) {
          // Preserve the original preparation failure.
        }
      }
      await _deleteIfPresent(path);
      throw _wavFileFailure(
        code: 'wav_file_prepare_failed',
        stage: AudioFailureStage.preparation,
        message: 'The WAV recording file could not be prepared.',
        cause: error,
      );
    }
  }

  /// Destination file path.
  final String path;

  @override
  final AudioFormat format;

  /// PCM representation stored in the WAV data chunk.
  final WavSampleEncoding encoding;

  /// Configured timeline-gap behavior.
  final WavGapPolicy gapPolicy;

  /// Configured abort cleanup behavior.
  final WavFileAbortPolicy abortPolicy;

  /// Maximum temporary encoding allocation per file write.
  final int encodingBufferBytes;

  @override
  AudioSinkCapabilities get capabilities => AudioSinkCapabilities.sequential;

  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast();
  final Stopwatch _clock = Stopwatch();
  RandomAccessFile? _file;
  AudioStreamKey? _stream;
  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  int _dataLength = 0;
  int? _expectedSampleOffset;
  int? _expectedSequence;
  Duration? _lastTimestamp;
  Future<void>? _writeFuture;
  Future<void>? _finishFuture;
  Future<void>? _abortFuture;
  Future<void>? _closeFuture;
  bool _abortRequested = false;

  /// Encoded audio bytes currently accepted, excluding the header.
  int get dataLength => _dataLength;

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

  @override
  Future<void> write(
    AudioFrame frame, {
    AudioCancellationToken? cancellationToken,
  }) {
    cancellationToken?.throwIfCancelled();
    if (_writeFuture != null) {
      return Future<void>.error(
        StateError('WAV file writes must be issued sequentially.'),
      );
    }
    if (_finishFuture != null ||
        _abortRequested ||
        _abortFuture != null ||
        _status.isTerminal) {
      return Future<void>.error(
        StateError('The WAV file session no longer accepts frames.'),
      );
    }

    late final Future<void> operation;
    operation = _write(frame, cancellationToken).whenComplete(() {
      if (identical(_writeFuture, operation)) {
        _writeFuture = null;
      }
    });
    _writeFuture = operation;
    return operation;
  }

  Future<void> _write(
    AudioFrame frame,
    AudioCancellationToken? cancellationToken,
  ) async {
    try {
      final int gapFrameCount = _validateFrame(frame);
      if (_status.state == AudioSessionState.prepared) {
        _transition(AudioSessionState.active);
      }
      final int bytesPerFrame = format.channels * encoding.bytesPerSample;
      final int additionalBytes =
          (gapFrameCount + frame.frameCount) * bytesPerFrame;
      if (_dataLength + additionalBytes > _maximumWavDataLength) {
        throw _wavFileFailure(
          code: 'wav_file_size_exceeded',
          stage: AudioFailureStage.encoding,
          message: 'The recording exceeds the WAV RIFF size limit.',
        );
      }

      if (gapFrameCount > 0) {
        await _writeSilence(gapFrameCount, cancellationToken);
      }
      await _writeSamples(frame.samples, cancellationToken);
      _stream ??= AudioStreamKey.fromFrame(frame);
      _expectedSampleOffset = frame.endSampleOffset;
      _expectedSequence = frame.sequence + 1;
      _lastTimestamp = frame.timestamp;
    } on _WavAbortRequested {
      throw const AudioCancelledException(
        AudioCancellation(reason: 'wav_sink_aborted'),
      );
    } on AudioCancelledException {
      _abortRequested = true;
      await _cleanupAfterTermination();
      _transition(AudioSessionState.aborted);
      rethrow;
    } on AudioFailure catch (failure) {
      await _fail(failure);
      rethrow;
    } catch (error) {
      final AudioFailure failure = _wavFileFailure(
        code: 'wav_file_write_failed',
        stage: AudioFailureStage.encoding,
        message: 'Audio could not be written to the WAV recording.',
        cause: error,
      );
      await _fail(failure);
      throw failure;
    }
  }

  int _validateFrame(AudioFrame frame) {
    if (frame.format != format) {
      throw _wavFileFailure(
        code: 'wav_file_format_mismatch',
        stage: AudioFailureStage.encoding,
        message: 'The frame format does not match the WAV session format.',
      );
    }
    final AudioStreamKey key = AudioStreamKey.fromFrame(frame);
    final AudioStreamKey? currentStream = _stream;
    if (currentStream != null && currentStream != key) {
      throw _wavFileFailure(
        code: 'wav_file_stream_mismatch',
        stage: AudioFailureStage.encoding,
        message: 'A WAV file session accepts one logical audio stream.',
      );
    }
    final int? expectedSequence = _expectedSequence;
    if (expectedSequence != null) {
      if (frame.sequence < expectedSequence) {
        throw _wavFileFailure(
          code: 'wav_file_sequence_regression',
          stage: AudioFailureStage.encoding,
          message: 'The frame sequence is overlapping or out of order.',
        );
      }
      if (frame.sequence != expectedSequence && frame.discontinuity == null) {
        throw _wavFileFailure(
          code: 'wav_file_sequence_gap',
          stage: AudioFailureStage.encoding,
          message: 'A sequence gap requires explicit discontinuity metadata.',
        );
      }
    }
    final Duration? lastTimestamp = _lastTimestamp;
    if (lastTimestamp != null && frame.timestamp < lastTimestamp) {
      throw _wavFileFailure(
        code: 'wav_file_timestamp_regression',
        stage: AudioFailureStage.encoding,
        message: 'Frame timestamps must be monotonic.',
      );
    }

    final int explicitGap = frame.discontinuity?.droppedSampleFrameCount ?? 0;
    final int? expectedOffset = _expectedSampleOffset;
    final int offsetGap;
    if (expectedOffset == null) {
      offsetGap = 0;
    } else {
      offsetGap = frame.sampleOffset - expectedOffset;
      if (offsetGap < 0) {
        throw _wavFileFailure(
          code: 'wav_file_offset_regression',
          stage: AudioFailureStage.encoding,
          message: 'Frame sample offsets are overlapping or out of order.',
        );
      }
    }
    final int gapFrameCount = offsetGap > explicitGap ? offsetGap : explicitGap;
    if (frame.discontinuity != null || gapFrameCount > 0) {
      if (gapPolicy == WavGapPolicy.reject) {
        throw _wavFileFailure(
          code: 'wav_file_discontinuity',
          stage: AudioFailureStage.encoding,
          message: 'A discontinuous stream cannot be recorded as lossless.',
        );
      }
    }
    return gapFrameCount;
  }

  Future<void> _writeSilence(
    int frameCount,
    AudioCancellationToken? cancellationToken,
  ) async {
    final int bytesPerFrame = format.channels * encoding.bytesPerSample;
    final int chunkLength =
        (encodingBufferBytes ~/ bytesPerFrame) * bytesPerFrame;
    final int boundedChunkLength = chunkLength == 0
        ? bytesPerFrame
        : chunkLength;
    final Uint8List zeroes = Uint8List(boundedChunkLength);
    var remainingBytes = frameCount * bytesPerFrame;
    while (remainingBytes > 0) {
      _checkActive(cancellationToken);
      final int length = remainingBytes < zeroes.length
          ? remainingBytes
          : zeroes.length;
      await _requireFile().writeFrom(zeroes, 0, length);
      _dataLength += length;
      remainingBytes -= length;
    }
  }

  Future<void> _writeSamples(
    Float32List samples,
    AudioCancellationToken? cancellationToken,
  ) async {
    final int bytesPerFrame = format.channels * encoding.bytesPerSample;
    final int framesPerChunk = encodingBufferBytes ~/ bytesPerFrame;
    final int samplesPerChunk = framesPerChunk * format.channels;
    var sampleOffset = 0;
    while (sampleOffset < samples.length) {
      _checkActive(cancellationToken);
      final int remaining = samples.length - sampleOffset;
      final int sampleCount = remaining < samplesPerChunk
          ? remaining
          : samplesPerChunk;
      final ByteData encoded = ByteData(sampleCount * encoding.bytesPerSample);
      switch (encoding) {
        case WavSampleEncoding.pcm16:
          for (var index = 0; index < sampleCount; index += 1) {
            final double value = samples[sampleOffset + index].clamp(-1.0, 1.0);
            final int scaled = value < 0
                ? (value * 32768).round()
                : (value * 32767).round();
            encoded.setInt16(index * 2, scaled, Endian.little);
          }
        case WavSampleEncoding.float32:
          for (var index = 0; index < sampleCount; index += 1) {
            encoded.setFloat32(
              index * 4,
              samples[sampleOffset + index],
              Endian.little,
            );
          }
      }
      await _requireFile().writeFrom(encoded.buffer.asUint8List());
      _dataLength += encoded.lengthInBytes;
      sampleOffset += sampleCount;
    }
  }

  void _checkActive(AudioCancellationToken? cancellationToken) {
    if (_abortRequested) {
      throw const _WavAbortRequested();
    }
    cancellationToken?.throwIfCancelled();
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    if (_status.state == AudioSessionState.finished) {
      return Future<void>.value();
    }
    if (_writeFuture != null) {
      return Future<void>.error(
        StateError('Wait for the current WAV write before finishing.'),
      );
    }
    if (_abortRequested || _abortFuture != null || _status.isTerminal) {
      return Future<void>.error(
        StateError('The WAV file session cannot be finished now.'),
      );
    }
    return _finishFuture ??= _finish(cancellationToken);
  }

  Future<void> _finish(AudioCancellationToken? cancellationToken) async {
    _transition(AudioSessionState.finishing);
    try {
      _checkActive(cancellationToken);
      await _finalizeFile(checkAbort: true);
      cancellationToken?.throwIfCancelled();
      _transition(AudioSessionState.finished);
    } on _WavAbortRequested {
      throw const AudioCancelledException(
        AudioCancellation(reason: 'wav_sink_aborted'),
      );
    } on AudioCancelledException {
      _abortRequested = true;
      await _cleanupAfterTermination();
      _transition(AudioSessionState.aborted);
      rethrow;
    } catch (error) {
      final AudioFailure failure = error is AudioFailure
          ? error
          : _wavFileFailure(
              code: 'wav_file_finalize_failed',
              stage: AudioFailureStage.encoding,
              message: 'The WAV recording could not be finalized.',
              cause: error,
            );
      await _fail(failure);
      throw failure;
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) {
    if (_status.state == AudioSessionState.closed ||
        _status.state == AudioSessionState.finished ||
        _status.state == AudioSessionState.aborted ||
        _status.state == AudioSessionState.failed) {
      return Future<void>.value();
    }
    return _abortFuture ??= _abort(failure);
  }

  Future<void> _abort(AudioFailure? failure) async {
    _abortRequested = true;
    try {
      await _writeFuture;
    } on Object {
      // The writer observes cancellation or its original failure.
    }
    try {
      await _finishFuture;
    } on Object {
      // The finisher observes cancellation or its original failure.
    }
    if (_status.state == AudioSessionState.aborted ||
        _status.state == AudioSessionState.failed) {
      return;
    }
    try {
      await _cleanupAfterTermination();
      _transition(
        failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
        failure: failure,
      );
    } catch (error) {
      final AudioFailure cleanupFailure = _wavFileFailure(
        code: 'wav_file_abort_failed',
        stage: AudioFailureStage.shutdown,
        message: 'The WAV recording could not be closed after abort.',
        cause: error,
      );
      _transition(AudioSessionState.failed, failure: cleanupFailure);
      throw cleanupFailure;
    }
  }

  Future<void> _fail(AudioFailure failure) async {
    _abortRequested = true;
    AudioFailure? cleanupFailure;
    try {
      await _cleanupAfterTermination();
    } catch (error) {
      cleanupFailure = _wavFileFailure(
        code: 'wav_file_failure_cleanup_failed',
        stage: AudioFailureStage.shutdown,
        message: 'The failed WAV recording could not be closed safely.',
        cause: error,
      );
    }
    _transition(AudioSessionState.failed, failure: cleanupFailure ?? failure);
  }

  Future<void> _cleanupAfterTermination() async {
    if (abortPolicy == WavFileAbortPolicy.finalizeAcceptedAudio) {
      try {
        await _finalizeFile(checkAbort: false);
        return;
      } catch (_) {
        await _closeFile();
        await _deleteIfPresent(path);
        rethrow;
      }
    }
    await _closeFile();
    await _deleteIfPresent(path);
  }

  Future<void> _finalizeFile({required bool checkAbort}) async {
    final RandomAccessFile? file = _file;
    if (file == null) {
      return;
    }
    if (checkAbort && _abortRequested) {
      throw const _WavAbortRequested();
    }
    await file.setPosition(0);
    if (checkAbort && _abortRequested) {
      throw const _WavAbortRequested();
    }
    await file.writeFrom(
      _wavHeader(format: format, encoding: encoding, dataLength: _dataLength),
    );
    if (checkAbort && _abortRequested) {
      throw const _WavAbortRequested();
    }
    await file.flush();
    await file.close();
    _file = null;
  }

  Future<void> _closeFile() async {
    final RandomAccessFile? file = _file;
    _file = null;
    if (file != null) {
      await file.close();
    }
  }

  RandomAccessFile _requireFile() {
    final RandomAccessFile? file = _file;
    if (file == null) {
      throw StateError('The WAV recording file is not open.');
    }
    return file;
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      if (!_status.isTerminal) {
        await abort();
      }
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await _closeFile();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _transition(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
    // Let ready observers receive the terminal state without awaiting stream
    // completion, which can be held indefinitely by a paused observer.
    await Future<void>.delayed(Duration.zero);
    _clock.stop();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
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

const int _maximumWavDataLength = 0xffffffff - 36;

final class _WavAbortRequested implements Exception {
  const _WavAbortRequested();
}

AudioFailure _wavFileFailure({
  required String code,
  required AudioFailureStage stage,
  required String message,
  Object? cause,
}) => AudioFailure(
  code: code,
  stage: stage,
  message: message,
  safeCause: cause?.runtimeType.toString(),
);

Uint8List _wavHeader({
  required AudioFormat format,
  required WavSampleEncoding encoding,
  required int dataLength,
}) {
  final ByteData header = ByteData(44);
  _writeAscii(header, 0, 'RIFF');
  header.setUint32(4, 36 + dataLength, Endian.little);
  _writeAscii(header, 8, 'WAVE');
  _writeAscii(header, 12, 'fmt ');
  header
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, encoding.formatCode, Endian.little)
    ..setUint16(22, format.channels, Endian.little)
    ..setUint32(24, format.sampleRate, Endian.little)
    ..setUint32(
      28,
      format.sampleRate * format.channels * encoding.bytesPerSample,
      Endian.little,
    )
    ..setUint16(32, format.channels * encoding.bytesPerSample, Endian.little)
    ..setUint16(34, encoding.bitsPerSample, Endian.little);
  _writeAscii(header, 36, 'data');
  header.setUint32(40, dataLength, Endian.little);
  return header.buffer.asUint8List();
}

void _writeAscii(ByteData data, int offset, String value) {
  for (var index = 0; index < value.length; index += 1) {
    data.setUint8(offset + index, value.codeUnitAt(index));
  }
}

Future<void> _deleteIfPresent(String path) async {
  final File file = File(path);
  if (await file.exists()) {
    await file.delete();
  }
}
