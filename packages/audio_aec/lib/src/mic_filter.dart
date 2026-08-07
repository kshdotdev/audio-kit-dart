// Adapted from Control Center's
// `lib/features/meetings/data/services/aec_mic_filter.dart`.
// Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.
//
// Adaptation notes:
//   - Control Center's filter is a pair of `Stream<Uint8List>` transforms
//     (`cleanMic`, `referenceTap`) that a recorder wires up by hand. This is one
//     [AudioSource]: it owns both capture sessions, and its own session is what
//     a caller routes downstream. The four policies below are carried over
//     unchanged; the lifecycle, cancellation, and frame metadata around them are
//     Audio Kit's.
//   - Block accumulation and delay estimation are NOT reimplemented here. They
//     are `AecBlockAccumulator` and `AecDelayEstimator` in `audio_processing`,
//     which is also where the original's copy-on-queue hazard went away: that
//     accumulator allocates each block instead of handing out views over a
//     reused buffer, so the aliasing bug the original guards against by copying
//     cannot occur.
//   - The lock gate is `AecDelayEstimator.hasLock`, which already implements
//     both of the original's tiers (single-measurement confidence, or repeated
//     agreement) with the same 0.55 default.
//   - The reference counters are named per block rather than per frame. They
//     always counted 10 ms blocks; "frame" means something else in Audio Kit.
//   - The far source is consumed exclusively as the AEC reference and is not
//     re-emitted. A caller that also needs the loopback audio downstream should
//     fan it out with `AudioRouter` before handing it here — fan-out is the
//     graph layer's job, not this package's.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';

import 'processor.dart';

/// Diagnostics a running [AecMicFilter] session exposes on top of the standard
/// [AudioSourceSession] contract.
abstract interface class AecMicFilterSession implements AudioSourceSession {
  /// Whether an engine is present, i.e. whether any cancellation is happening.
  ///
  /// `false` means this session is a pure passthrough.
  bool get isActive;

  /// Whether the far→near delay has been measured with enough confidence to
  /// buffer the microphone.
  ///
  /// Until this is `true` the filter is in fail-safe passthrough: audio still
  /// goes through the engine, but with no added latency and no delay hint.
  bool get isLocked;

  /// Delay hint currently fed to the engine, in milliseconds.
  int get streamDelayMs;

  /// Microphone buffering currently applied, in milliseconds.
  ///
  /// Zero until [isLocked]. This is latency the filter deliberately adds so the
  /// far-end reference leads the capture.
  int get micBufferMs;

  /// Blocks processed with a real, matched far-end reference available.
  int get referenceBlocksMatched;

  /// Blocks whose far-end reference had to be zero-padded because the loopback
  /// had stalled.
  ///
  /// A steadily climbing count here means the reference stream is not keeping
  /// up, and cancellation quality is degrading for a reason that has nothing to
  /// do with the engine.
  int get referenceBlocksZeroPadded;

  /// Most recent smoothed delay measurement, or `null` while warming up.
  AecDelayEstimate? get lastDelayEstimate;

  /// The engine's current echo metrics, or [AecMetrics.empty] when passthrough.
  AecMetrics metrics();
}

/// Composes a microphone source and a loopback reference source into a single
/// echo-cancelled [AudioSource].
///
/// ## What it does
///
/// The microphone picks up whatever is playing out of the speakers. Downstream
/// recognition transcribes that bleed as a degraded duplicate of the far side,
/// wrongly attributed to the local speaker. This feeds the loopback capture to
/// an [AecEngine] as the far-end reference and subtracts it from the microphone
/// at the signal level, emitting cleaned float32 frames.
///
/// ## Per-session auto-calibration
///
/// The microphone and the loopback are two independent operating-system
/// captures with different, drifting clocks and a delivery offset that depends
/// entirely on the user's audio hardware — so the engine alone cannot lock onto
/// the echo. [AecDelayEstimator] measures the real offset live by
/// cross-correlating the two energy envelopes on one shared arrival clock. This
/// filter then (a) buffers the microphone so the reference reliably *leads* the
/// capture and (b) feeds the engine a real stream-delay hint, refined as the
/// clocks drift. Nothing is hardcoded to one machine.
///
/// ## Four policies carried from the reference implementation
///
/// 1. **Eager, never-paused consumption.** Both captures are subscribed to
///    eagerly and never paused, so the engine sees both channels in real time
///    even while a downstream consumer stalls. Backpressure buffers this
///    filter's own output controller, never the capture. Pausing a realtime
///    capture to apply backpressure would starve the render buffer and silently
///    degrade cancellation, so the emitted stream rejects `pause` outright.
/// 2. **Reference-availability gate.** The engine expects one render block per
///    capture block. If the loopback stalls, the reference is **zero-padded**
///    rather than cancelling against a stale echo, and the
///    [AecMicFilterSession.referenceBlocksZeroPadded] counter says so.
/// 3. **Fail-safe passthrough.** Until the delay locks, the microphone passes
///    through the engine with no buffering and no delay hint — never worse than
///    the no-AEC baseline. With no engine at all, output is byte-for-byte the
///    input.
/// 4. **Lock once, track forever.** On lock, the microphone buffer is sized once
///    so the reference leads by [targetLeadMs]; afterwards the delay hint keeps
///    following the live measurement so it tracks clock drift.
///
/// ## Lifetime
///
/// One filter drives exactly one session, because the engine behind it is a
/// single stateful native instance. [prepare] throws [StateError] on a second
/// call, and closing the session disposes the engine.
///
/// **Main-isolate only**, inherited from [AecProcessor]; see its documentation.
final class AecMicFilter implements AudioSource {
  /// Creates a filter over a microphone source [near] and a loopback reference
  /// source [far].
  ///
  /// A `null` [processor] makes this a pure identity passthrough of [near]; in
  /// that mode [far] is never prepared, because there is nothing to reference.
  /// That is the in-person capture mode, not an availability fallback: a missing
  /// native library should surface as [AecUnavailable] from
  /// [AecProcessor.create], not be quietly swallowed here.
  ///
  /// [clockNow] supplies the shared arrival clock both captures are stamped
  /// against, in milliseconds. It defaults to a monotonic clock started when the
  /// session starts; tests inject their own to make calibration deterministic.
  ///
  /// [log] receives human-readable calibration and metrics lines.
  AecMicFilter({
    required this.near,
    this.far,
    this.processor,
    this.sourceId,
    this.trackId,
    this.clockId,
    this.clockNow,
    this.log,
  }) {
    if (processor != null && far == null) {
      throw ArgumentError.value(
        far,
        'far',
        'An echo canceller needs a far-end reference source. Pass one, or '
            'construct AecMicFilter.passthrough for in-person capture.',
      );
    }
  }

  /// Creates an identity passthrough of [near] with no cancellation.
  ///
  /// Use this for in-person capture, where there is no loopback and therefore
  /// nothing to cancel. Emitted frames carry this session's identifiers but
  /// otherwise reproduce the input exactly.
  AecMicFilter.passthrough({
    required this.near,
    this.sourceId,
    this.trackId,
    this.clockId,
    this.log,
  }) : far = null,
       processor = null,
       clockNow = null;

  /// Desired far-end lead after microphone buffering, in milliseconds.
  ///
  /// A comfortable positive delay, well inside the engine's render-buffer range.
  static const int targetLeadMs = 80;

  /// Upper clamp on the delay hint handed to the engine, in milliseconds.
  static const int maxStreamDelayMs = 500;

  /// How often the far→near offset is re-measured, in milliseconds.
  static const int calibrateIntervalMs = 500;

  /// How often a status line is emitted to [log], in milliseconds.
  static const int logIntervalMs = 2000;

  /// Microphone source to clean.
  final AudioSource near;

  /// Loopback reference source, or `null` in passthrough mode.
  final AudioSource? far;

  /// Engine doing the cancellation, or `null` in passthrough mode.
  final AecEngine? processor;

  /// Source identifier for emitted frames; defaults to the microphone's with an
  /// `.aec` suffix.
  final String? sourceId;

  /// Track identifier for emitted frames; defaults to the microphone's.
  final String? trackId;

  /// Clock identifier for emitted frames.
  ///
  /// Defaults to the microphone's with an `.aec` suffix, because the output is
  /// genuinely a different timeline: sample offsets restart at zero and are
  /// shifted by however much the microphone is buffered.
  final String? clockId;

  /// Shared arrival clock in milliseconds, or `null` to use a monotonic clock
  /// started at session start.
  final int Function()? clockNow;

  /// Receives calibration and metrics lines.
  final void Function(String message)? log;

  bool _prepared = false;

  @override
  Future<AecMicFilterSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (_prepared) {
      throw StateError(
        'An AecMicFilter drives exactly one session: the engine behind it is a '
        'single stateful native instance. Construct another filter (with '
        'another engine) for another session.',
      );
    }
    _prepared = true;

    final AudioSourceSession nearSession = await near.prepare(
      cancellationToken: cancellationToken,
    );
    AudioSourceSession? farSession;
    try {
      _requireFormat(nearSession.format, 'near');
      final AudioSource? farSource = far;
      if (processor != null && farSource != null) {
        farSession = await farSource.prepare(
          cancellationToken: cancellationToken,
        );
        _requireFormat(farSession.format, 'far');
        if (farSession.format != nearSession.format) {
          throw ArgumentError(
            'The microphone and the loopback reference must share one format: '
            'near is ${nearSession.format}, far is ${farSession.format}. '
            'Resample or downmix before the filter.',
          );
        }
      }
    } on Object {
      await farSession?.close();
      await nearSession.close();
      // A failed prepare consumes this one-shot filter. Release the native
      // processor here as no session exists whose close path could own it.
      processor?.dispose();
      rethrow;
    }

    return _AecMicFilterSession(
      filter: this,
      nearSession: nearSession,
      farSession: farSession,
    );
  }

  void _requireFormat(AudioFormat format, String role) {
    final AecEngine? engine = processor;
    if (engine == null) {
      return;
    }
    if (format.channels != 1) {
      throw ArgumentError.value(
        format.channels,
        '$role format channels',
        'Echo cancellation is mono only. Downmix before the filter.',
      );
    }
    if (format.sampleRate != engine.sampleRate) {
      throw ArgumentError.value(
        format.sampleRate,
        '$role format sampleRate',
        'The engine was created for ${engine.sampleRate} Hz. Feeding it a '
            'different rate produces no error and no cancellation, so it is '
            'rejected here. Resample before the filter.',
      );
    }
  }
}

final class _AecMicFilterSession implements AecMicFilterSession {
  _AecMicFilterSession({
    required AecMicFilter filter,
    required AudioSourceSession nearSession,
    required AudioSourceSession? farSession,
  }) : _filter = filter,
       _near = nearSession,
       _far = farSession,
       _engine = filter.processor,
       sourceId = filter.sourceId ?? '${nearSession.sourceId}.aec',
       trackId = filter.trackId ?? nearSession.trackId,
       clockId = filter.clockId ?? '${nearSession.clockId}.aec' {
    final AecEngine? engine = _engine;
    if (engine != null) {
      _blockFrames = engine.blockFrames;
      _blockMs = (_blockFrames * 1000) ~/ engine.sampleRate;
      _nearBlocks = AecBlockAccumulator(blockFrames: _blockFrames);
      _farBlocks = AecBlockAccumulator(blockFrames: _blockFrames);
      _estimator = AecDelayEstimator();
      _silence = Int16List(_blockFrames);
    }
  }

  final AecMicFilter _filter;
  final AudioSourceSession _near;
  final AudioSourceSession? _far;
  final AecEngine? _engine;

  @override
  final String sourceId;
  @override
  final String trackId;
  @override
  final String clockId;

  // Engine-shaped state; all null in passthrough mode.
  late final int _blockFrames;
  late final int _blockMs;
  late final AecBlockAccumulator _nearBlocks;
  late final AecBlockAccumulator _farBlocks;
  late final AecDelayEstimator _estimator;
  late final Int16List _silence;

  /// Microphone blocks awaiting processing, held back by [_nearBufferBlocks] so
  /// the far-end reference leads the capture.
  final Queue<Int16List> _nearQueue = Queue<Int16List>();
  int _nearBufferBlocks = 0;
  int _streamDelayMs = 0;
  bool _locked = false;
  AecDelayEstimate? _lastEstimate;

  // Reference-availability gate: the engine expects one render block per capture
  // block, so a stalled loopback is padded rather than left to go stale.
  int _farBlocksFed = 0;
  int _nearBlocksProcessed = 0;
  int _refMatched = 0;
  int _refZeroPadded = 0;

  int _lastCalibrateMs = -1 << 30;
  int _lastLogMs = -1 << 30;

  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>();
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _frames.stream,
    // Never pausable. Pausing would propagate backpressure into a realtime
    // capture and starve the engine's render buffer; buffering this
    // controller instead is the whole point of the eager-consumption policy.
    pauseSupported: false,
  );
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast();
  final Stopwatch _clock = Stopwatch();

  AudioSessionStatus _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );
  StreamSubscription<AudioFrame>? _nearSub;
  StreamSubscription<AudioFrame>? _farSub;
  Future<void>? _startFuture;
  Future<void>? _closeFuture;
  AudioDiscontinuity? _pendingDiscontinuity;
  int _sequence = 0;
  int _sampleOffset = 0;
  bool _aborted = false;

  @override
  bool get isActive => _engine != null;

  @override
  bool get isLocked => _locked;

  @override
  int get streamDelayMs => _streamDelayMs;

  @override
  int get micBufferMs => _engine == null ? 0 : _nearBufferBlocks * _blockMs;

  @override
  int get referenceBlocksMatched => _refMatched;

  @override
  int get referenceBlocksZeroPadded => _refZeroPadded;

  @override
  AecDelayEstimate? get lastDelayEstimate => _lastEstimate;

  @override
  AecMetrics metrics() => _engine?.metrics() ?? AecMetrics.empty;

  @override
  AudioFormat get format => _near.format;

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities(
    isRealtime: _near.capabilities.isRealtime,
    supportsPause: false,
  );

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

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    return _startFuture ??= _start(cancellationToken);
  }

  Future<void> _start(AudioCancellationToken? cancellationToken) async {
    if (_status.state != AudioSessionState.prepared) {
      throw StateError('An AEC filter session can only start once.');
    }
    _clock.start();
    _transition(AudioSessionState.starting);

    // Subscribe before starting: sessions emit only after start, so this cannot
    // miss a frame, and it guarantees the reference is being consumed from the
    // engine's very first block.
    final AudioSourceSession? farSession = _far;
    if (farSession != null) {
      _farSub = farSession.frames.listen(
        _onFarFrame,
        onError: _forwardError,
        cancelOnError: false,
      );
    }
    _nearSub = _near.frames.listen(
      _onNearFrame,
      onError: _forwardError,
      onDone: _onNearDone,
      cancelOnError: false,
    );

    try {
      // Reference first, so the render buffer has audio in it before the first
      // capture block arrives and the zero-pad gate has less to cover.
      await farSession?.start(cancellationToken: cancellationToken);
      await _near.start(cancellationToken: cancellationToken);
    } on Object catch (error) {
      await abort(
        failure: AudioFailure(
          code: 'aec_filter_start_failed',
          stage: AudioFailureStage.startup,
          message: 'An AEC filter capture source failed to start.',
          safeCause: error.runtimeType.toString(),
        ),
      );
      rethrow;
    }
    if (!_aborted) {
      _transition(AudioSessionState.active);
    }
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    throw UnsupportedError(
      'An AEC filter cannot be paused: the engine must keep seeing both '
      'channels in real time, and pausing would desynchronize the reference '
      'from the capture for everything that follows.',
    );
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    throw UnsupportedError('An AEC filter cannot be paused, so nor resumed.');
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_status.isTerminal) {
      return;
    }
    _transition(AudioSessionState.finishing);
    await _near.stop(cancellationToken: cancellationToken);
    await _far?.stop(cancellationToken: cancellationToken);
    _finishNear();
    if (!_status.isTerminal) {
      _transition(AudioSessionState.finished);
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (_aborted || _status.state == AudioSessionState.closed) {
      return;
    }
    _aborted = true;
    await _cancelSubscriptions();
    await _near.abort(failure: failure);
    await _far?.abort(failure: failure);
    _nearQueue.clear();
    _closeFrames();
    _transition(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  /// Shutdown order is load-bearing.
  ///
  /// Both capture subscriptions are cancelled first, so no block can be in
  /// flight; only then is the engine disposed. Disposing an engine while a
  /// block is being processed frees the native instance out from under the call
  /// — a use-after-free, not merely a lost block.
  Future<void> _close() async {
    if (!_status.isTerminal) {
      await abort();
    }
    await _cancelSubscriptions();
    await _near.close();
    await _far?.close();
    _nearQueue.clear();
    _closeFrames();
    _engine?.dispose();
    _transition(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
    _clock.stop();
  }

  Future<void> _cancelSubscriptions() async {
    await _nearSub?.cancel();
    _nearSub = null;
    await _farSub?.cancel();
    _farSub = null;
  }

  int _now() =>
      _filter.clockNow?.call() ?? _clock.elapsed.inMicroseconds ~/ 1000;

  void _onNearFrame(AudioFrame frame) {
    if (_frames.isClosed || _aborted) {
      return;
    }
    final AudioDiscontinuity? discontinuity = frame.discontinuity;
    if (discontinuity != null) {
      _pendingDiscontinuity = discontinuity;
    }

    final AecEngine? engine = _engine;
    if (engine == null) {
      // True identity: the samples are reproduced exactly, only the timeline
      // metadata becomes this session's.
      _emit(frame.samples, owned: false);
      return;
    }

    if (discontinuity != null &&
        (discontinuity.reason == AudioDiscontinuityReason.sourceRestart ||
            discontinuity.reason == AudioDiscontinuityReason.clockReset)) {
      // A restart or clock reset invalidates the measured offset outright: it
      // described hardware timing that is no longer in the path. Merely dropped
      // frames are left alone — the estimator's rolling window re-converges on
      // its own, and dropping the lock there would thrash on a lossy route.
      _resetAlignment(engine);
    }

    final int nowMs = _now();
    final List<Int16List> cleaned = <Int16List>[];
    _nearBlocks.add(frame.samples, (Int16List block) {
      _estimator.addNear(nowMs, AecDelayEstimator.rms(pcm16ToFloat(block)));
      _nearQueue.add(block);
      _maybeCalibrate(nowMs);
      _drainNearQueue(engine, cleaned, keepBlocks: _nearBufferBlocks);
    });
    _emitBlocks(cleaned);
  }

  void _onFarFrame(AudioFrame frame) {
    final AecEngine? engine = _engine;
    if (engine == null || _frames.isClosed || _aborted) {
      return;
    }
    final int nowMs = _now();
    _farBlocks.add(frame.samples, (Int16List block) {
      _estimator.addFar(nowMs, AecDelayEstimator.rms(pcm16ToFloat(block)));
      engine.processReverse(block);
      _farBlocksFed += 1;
    });
  }

  void _onNearDone() {
    _finishNear();
    if (!_status.isTerminal && _status.state != AudioSessionState.finishing) {
      _transition(AudioSessionState.finished);
    }
  }

  /// Flushes everything still held back and closes the output.
  ///
  /// End of stream is the one moment a partial block may be padded: mid-stream
  /// padding would insert a silent gap into the engine's timeline and
  /// desynchronize the reference from the capture for everything after it.
  void _finishNear() {
    if (_frames.isClosed || _aborted) {
      return;
    }
    final AecEngine? engine = _engine;
    if (engine != null) {
      final Int16List? tail = _nearBlocks.drain();
      if (tail != null) {
        _nearQueue.add(tail);
      }
      final List<Int16List> cleaned = <Int16List>[];
      _drainNearQueue(engine, cleaned, keepBlocks: 0);
      _emitBlocks(cleaned);
    }
    _closeFrames();
  }

  /// Processes queued microphone blocks until only [keepBlocks] remain.
  ///
  /// The reference-availability gate lives here: when the loopback has fallen
  /// behind, the reference is zero-padded so the render and capture streams stay
  /// aligned, instead of cancelling this block against a stale echo.
  void _drainNearQueue(
    AecEngine engine,
    List<Int16List> out, {
    required int keepBlocks,
  }) {
    while (_nearQueue.length > keepBlocks) {
      if (_farBlocksFed <= _nearBlocksProcessed) {
        engine.processReverse(_silence);
        _farBlocksFed += 1;
        _refZeroPadded += 1;
      } else {
        _refMatched += 1;
      }
      out.add(engine.processCapture(_nearQueue.removeFirst(), _streamDelayMs));
      _nearBlocksProcessed += 1;
    }
  }

  /// Re-measures the far→near offset and, once, locks the microphone buffer;
  /// afterwards the delay hint keeps following the live measurement so it tracks
  /// clock drift. Throttled against the shared clock and driven from the
  /// microphone path, which is the cancellation timeline.
  void _maybeCalibrate(int nowMs) {
    if (nowMs - _lastCalibrateMs < AecMicFilter.calibrateIntervalMs) {
      return;
    }
    _lastCalibrateMs = nowMs;

    final AecDelayEstimate? estimate = _estimator.estimateSmoothed();
    if (estimate != null) {
      _lastEstimate = estimate;
      if (!_locked && _estimator.hasLock(estimate)) {
        // Buffer the microphone so the far end leads by the target margin.
        final int deficitMs = AecMicFilter.targetLeadMs - estimate.lagMs;
        _nearBufferBlocks = deficitMs <= 0 ? 0 : (deficitMs / _blockMs).round();
        _locked = true;
        _streamDelayMs = _clampDelay(
          estimate.lagMs + _nearBufferBlocks * _blockMs,
        );
        _filter.log?.call(
          'AEC delay locked: far-lead ${estimate.lagMs}ms '
          '(confidence ${estimate.confidence.toStringAsFixed(2)}) -> '
          'mic buffer ${micBufferMs}ms, stream-delay ${_streamDelayMs}ms',
        );
      } else {
        _streamDelayMs = _clampDelay(
          estimate.lagMs + _nearBufferBlocks * _blockMs,
        );
      }
    }

    if (nowMs - _lastLogMs >= AecMicFilter.logIntervalMs) {
      _lastLogMs = nowMs;
      _logStatus(estimate);
    }
  }

  void _resetAlignment(AecEngine engine) {
    // Emit what is already buffered rather than dropping it: those samples are
    // still valid audio, they simply belong to the timeline that just ended.
    final List<Int16List> cleaned = <Int16List>[];
    _drainNearQueue(engine, cleaned, keepBlocks: 0);
    _emitBlocks(cleaned);
    _nearBlocks.reset();
    _farBlocks.reset();
    _estimator.reset();
    _locked = false;
    _nearBufferBlocks = 0;
    _streamDelayMs = 0;
    _lastEstimate = null;
    _lastCalibrateMs = -1 << 30;
    _filter.log?.call(
      'AEC alignment reset after a capture discontinuity; back to fail-safe '
      'passthrough until the delay locks again.',
    );
  }

  int _clampDelay(int ms) => ms < 0
      ? 0
      : (ms > AecMicFilter.maxStreamDelayMs
            ? AecMicFilter.maxStreamDelayMs
            : ms);

  void _logStatus(AecDelayEstimate? estimate) {
    final void Function(String)? log = _filter.log;
    if (log == null) {
      return;
    }
    final AecMetrics metric = metrics();
    final String raw = estimate == null
        ? 'far-lead n/a (warming up)'
        : 'far-lead ${estimate.lagMs}ms '
              '(confidence ${estimate.confidence.toStringAsFixed(2)})';
    String show(double? value) =>
        value == null ? 'n/a' : value.toStringAsFixed(1);
    log(
      'AEC cal: $raw | ${_locked ? 'LOCKED' : 'unlocked'} '
      'buffer ${micBufferMs}ms stream-delay ${_streamDelayMs}ms '
      '| ERLE ${show(metric.erle)}dB delay ${metric.delayMs ?? 'n/a'}ms '
      'residual ${show(metric.residual)} '
      '| reference matched $_refMatched zero-padded $_refZeroPadded',
    );
  }

  void _emitBlocks(List<Int16List> blocks) {
    if (blocks.isEmpty) {
      return;
    }
    if (blocks.length == 1) {
      _emit(pcm16ToFloat(blocks.first));
      return;
    }
    var total = 0;
    for (final Int16List block in blocks) {
      total += block.length;
    }
    final Float32List samples = Float32List(total);
    var offset = 0;
    for (final Int16List block in blocks) {
      samples.setAll(offset, pcm16ToFloat(block));
      offset += block.length;
    }
    _emit(samples);
  }

  void _emit(Float32List samples, {bool owned = true}) {
    if (_frames.isClosed || samples.isEmpty) {
      return;
    }
    final AudioDiscontinuity? discontinuity = _pendingDiscontinuity;
    _pendingDiscontinuity = null;
    final AudioFrame frame = owned
        ? AudioFrame.owned(
            format: format,
            samples: samples,
            sourceId: sourceId,
            trackId: trackId,
            clockId: clockId,
            sequence: _sequence,
            sampleOffset: _sampleOffset,
            timestamp: format.durationForFrames(_sampleOffset),
            discontinuity: discontinuity,
          )
        : AudioFrame(
            format: format,
            samples: samples,
            sourceId: sourceId,
            trackId: trackId,
            clockId: clockId,
            sequence: _sequence,
            sampleOffset: _sampleOffset,
            timestamp: format.durationForFrames(_sampleOffset),
            discontinuity: discontinuity,
          );
    _sequence += 1;
    _sampleOffset += frame.frameCount;
    _frames.add(frame);
  }

  void _forwardError(Object error, StackTrace stackTrace) {
    if (!_frames.isClosed) {
      _frames.addError(error, stackTrace);
    }
  }

  void _closeFrames() {
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
