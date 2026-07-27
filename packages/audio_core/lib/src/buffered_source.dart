import 'dart:async';
import 'dart:typed_data';

import 'cancellation.dart';
import 'capabilities.dart';
import 'failure.dart';
import 'format.dart';
import 'frame.dart';
import 'frame_stream.dart';
import 'session.dart';

/// Cold finite audio source backed by an owned in-memory PCM buffer.
final class BufferedAudioSource implements AudioSource {
  /// Creates a source by copying [samples].
  factory BufferedAudioSource({
    required AudioFormat format,
    required Float32List samples,
    required String sourceId,
    String trackId = 'audio',
    String? clockId,
    int chunkFrameCount = 1600,
  }) => BufferedAudioSource.owned(
    format: format,
    samples: Float32List.fromList(samples),
    sourceId: sourceId,
    trackId: trackId,
    clockId: clockId,
    chunkFrameCount: chunkFrameCount,
  );

  /// Creates a source by taking exclusive ownership of [samples].
  BufferedAudioSource.owned({
    required this.format,
    required this.samples,
    required this.sourceId,
    this.trackId = 'audio',
    String? clockId,
    this.chunkFrameCount = 1600,
  }) : clockId = clockId ?? '$sourceId.timeline' {
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', 'Must not be empty.');
    }
    if (samples.length % format.channels != 0) {
      throw ArgumentError.value(
        samples.length,
        'samples',
        'Length must be divisible by the channel count.',
      );
    }
    if (sourceId.trim().isEmpty ||
        trackId.trim().isEmpty ||
        this.clockId.trim().isEmpty) {
      throw ArgumentError('Audio source identifiers must not be empty.');
    }
    if (chunkFrameCount <= 0) {
      throw ArgumentError.value(
        chunkFrameCount,
        'chunkFrameCount',
        'Must be positive.',
      );
    }
  }

  /// Buffer format.
  final AudioFormat format;

  /// Exclusively owned interleaved samples.
  final Float32List samples;

  /// Source ID assigned to generated frames.
  final String sourceId;

  /// Track ID assigned to generated frames.
  final String trackId;

  /// Timeline clock ID assigned to generated frames.
  final String clockId;

  /// Maximum sample frames per emitted [AudioFrame].
  final int chunkFrameCount;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return _BufferedAudioSourceSession(this);
  }
}

final class _BufferedAudioSourceSession implements AudioSourceSession {
  _BufferedAudioSourceSession(this._source);

  final BufferedAudioSource _source;
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

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.pausable;

  @override
  String get clockId => _source.clockId;

  @override
  AudioFormat get format => _source.format;

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  String get sourceId => _source.sourceId;

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
  String get trackId => _source.trackId;

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    return _startFuture ??= _start(cancellationToken);
  }

  Future<void> _start(AudioCancellationToken? cancellationToken) async {
    if (_status.state != AudioSessionState.prepared) {
      throw StateError('Buffered audio can only start from prepared state.');
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
    final int samplesPerChunk = _source.chunkFrameCount * format.channels;
    var sampleIndex = 0;
    var sequence = 0;
    try {
      while (sampleIndex < _source.samples.length &&
          !_stopRequested &&
          !_aborted) {
        cancellationToken?.throwIfCancelled();
        final Completer<void>? gate = _resumeGate;
        if (gate != null) {
          await gate.future;
          cancellationToken?.throwIfCancelled();
          if (_stopRequested || _aborted) {
            break;
          }
        }
        final int end = _minimum(
          sampleIndex + samplesPerChunk,
          _source.samples.length,
        );
        final int sampleOffset = sampleIndex ~/ format.channels;
        _frames.add(
          AudioFrame.owned(
            format: format,
            samples: Float32List.fromList(
              _source.samples.sublist(sampleIndex, end),
            ),
            sourceId: sourceId,
            trackId: trackId,
            clockId: clockId,
            sequence: sequence,
            sampleOffset: sampleOffset,
            timestamp: format.durationForFrames(sampleOffset),
          ),
        );
        sampleIndex = end;
        sequence += 1;
        // Give listeners and cooperative cancellation an opportunity between
        // finite chunks without tying delivery to wall-clock playback time.
        await Future<void>.delayed(Duration.zero);
      }
      if (!_frames.isClosed) {
        _requestFrameClose();
      }
      if (!_aborted) {
        _transition(AudioSessionState.finished);
      }
    } on AudioCancelledException catch (error) {
      await abort(
        failure: AudioFailure(
          code: 'buffered_source_cancelled',
          stage: AudioFailureStage.processing,
          message: 'Buffered audio delivery was cancelled.',
          safeCause: error.runtimeType.toString(),
        ),
      );
      rethrow;
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
      throw StateError('Only active buffered audio can be paused.');
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
    if (_status.state == AudioSessionState.finished ||
        _status.state == AudioSessionState.aborted ||
        _status.state == AudioSessionState.failed ||
        _status.state == AudioSessionState.closed) {
      return;
    }
    _stopRequested = true;
    _releasePause();
    await _awaitStartIgnoringFailure();
    if (_startFuture == null) {
      if (!_frames.isClosed) {
        _requestFrameClose();
      }
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
    if (!_frames.isClosed) {
      _requestFrameClose();
    }
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
    if (!_frames.isClosed) {
      _requestFrameClose();
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
      // The caller of start observes the original failure. Cleanup remains
      // deterministic and must not replay it from close/stop.
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

int _minimum(int left, int right) => left < right ? left : right;
