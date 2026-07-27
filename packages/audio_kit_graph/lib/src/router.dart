import 'dart:async';
import 'dart:collection';

import 'package:audio_core/audio_core.dart';

import 'events.dart';
import 'metrics.dart';
import 'options.dart';

/// Failure raised when an operation is invalid for the router lifecycle.
final class AudioRouterStateError extends StateError {
  /// Creates a router lifecycle error.
  AudioRouterStateError(super.message);
}

/// A bounded fan-out router with one independent mailbox per route.
final class AudioRouter {
  /// Creates a router for one fixed PCM format.
  AudioRouter({required this.format, required this.upstreamPausable});

  /// Fixed format accepted by this router and all attached sinks.
  final AudioFormat format;

  /// Whether callers can safely honor `blockUpstream`.
  final bool upstreamPausable;

  final Map<String, _RouteMailbox> _mailboxes = <String, _RouteMailbox>{};
  final Set<_RouteMailbox> _ownedMailboxes = <_RouteMailbox>{};
  final StreamController<AudioRouteEvent> _events =
      StreamController<AudioRouteEvent>.broadcast(sync: true);
  Future<void>? _activeDispatch;
  bool _dispatchActive = false;
  Future<void>? _finishFuture;
  Future<void>? _abortFuture;
  Future<void>? _closeFuture;
  bool _accepting = true;
  bool _aborting = false;

  /// Broadcast events from every attached route.
  Stream<AudioRouteEvent> get events => _events.stream;

  /// Whether new frames and routes are accepted.
  bool get isAccepting => _accepting;

  /// Current dynamically attached routes.
  Iterable<AudioRoute> get routes => List<AudioRoute>.unmodifiable(
    _mailboxes.values.map((mailbox) => mailbox.handle),
  );

  /// Attaches [sink] and transfers its finish/abort/close ownership to the route.
  AudioRoute attach({
    required String id,
    required AudioSinkSession sink,
    required AudioRouteOptions options,
  }) {
    if (!_accepting) {
      throw AudioRouterStateError('Cannot attach to a finishing router.');
    }
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be empty.');
    }
    if (_ownedMailboxes.any((mailbox) => mailbox.id == id)) {
      throw StateError('Audio route "$id" is already attached.');
    }
    if (sink.format != format) {
      throw ArgumentError.value(
        sink.format,
        'sink',
        'Sink format must match router format $format.',
      );
    }
    if (options.overflowPolicy == AudioOverflowPolicy.blockUpstream &&
        !upstreamPausable) {
      throw ArgumentError.value(
        options.overflowPolicy,
        'options',
        'blockUpstream requires a pausable upstream.',
      );
    }

    late final _RouteMailbox mailbox;
    mailbox = _RouteMailbox(
      id: id,
      sink: sink,
      options: options,
      emitToRouter: _emit,
      onTerminal: () {
        if (identical(_mailboxes[id], mailbox)) {
          _mailboxes.remove(id);
        }
      },
      onDisposed: () {
        _ownedMailboxes.remove(mailbox);
      },
    );
    _mailboxes[id] = mailbox;
    _ownedMailboxes.add(mailbox);
    mailbox.activate();
    return mailbox.handle;
  }

  /// Submits one frame to all routes attached at call time.
  ///
  /// Live routers admit synchronously into bounded route mailboxes. For a
  /// pausable upstream, callers must await each dispatch; a concurrent call is
  /// rejected instead of being retained in an unbounded future chain.
  Future<AudioDispatchReport> add(AudioFrame frame) {
    if (!_accepting) {
      return Future<AudioDispatchReport>.error(
        AudioRouterStateError('Cannot add frames after finish or abort.'),
      );
    }
    if (frame.format != format) {
      return Future<AudioDispatchReport>.error(
        ArgumentError.value(
          frame.format,
          'frame',
          'Frame format must match router format $format.',
        ),
      );
    }

    final snapshot = List<_RouteMailbox>.of(_mailboxes.values);
    if (!upstreamPausable) {
      try {
        return Future<AudioDispatchReport>.value(
          AudioDispatchReport(<String, AudioDispatchOutcome>{
            for (final mailbox in snapshot)
              mailbox.id: mailbox.enqueueRealtime(frame),
          }),
        );
      } catch (error, stackTrace) {
        return Future<AudioDispatchReport>.error(error, stackTrace);
      }
    }

    if (_dispatchActive) {
      return Future<AudioDispatchReport>.error(
        AudioRouterStateError(
          'A pausable router dispatch is already active; await add() before '
          'submitting the next frame.',
        ),
      );
    }
    _dispatchActive = true;
    final Future<AudioDispatchReport> dispatch = _dispatchPausable(
      frame,
      snapshot,
    );
    _activeDispatch = dispatch.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return dispatch;
  }

  Future<AudioDispatchReport> _dispatchPausable(
    AudioFrame frame,
    List<_RouteMailbox> snapshot,
  ) async {
    try {
      final outcomes = <String, AudioDispatchOutcome>{};
      for (final mailbox in snapshot) {
        outcomes[mailbox.id] = await mailbox.enqueue(frame);
      }
      return AudioDispatchReport(outcomes);
    } finally {
      _dispatchActive = false;
    }
  }

  /// Stops admission, drains every route, and gracefully finishes its sink.
  Future<void> finish() {
    _accepting = false;
    return _finishFuture ??= _finish();
  }

  Future<void> _finish() async {
    await _activeDispatch;
    final pending = List<_RouteMailbox>.of(_ownedMailboxes);
    await Future.wait(pending.map((mailbox) => mailbox.finish()));
  }

  /// Stops admission and immediately aborts every route.
  Future<void> abort({AudioFailure? failure}) {
    _accepting = false;
    _aborting = true;
    return _abortFuture ??= _abort(
      failure ??
          AudioFailure(
            code: 'router_aborted',
            stage: AudioFailureStage.routing,
            message: 'Audio routing was aborted.',
          ),
    );
  }

  Future<void> _abort(AudioFailure failure) async {
    final pending = List<_RouteMailbox>.of(_ownedMailboxes);
    await Future.wait(
      pending.map((mailbox) => mailbox.abort(failure: failure)),
    );
  }

  /// Finishes active routes and closes the event stream exactly once.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      if (_aborting) {
        await (_abortFuture ?? Future<void>.value());
      } else {
        await finish();
      }
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }

  void _emit(AudioRouteEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }
}

/// Handle for metrics, events, and dynamic detachment of one route.
final class AudioRoute {
  AudioRoute._(this._mailbox);

  final _RouteMailbox _mailbox;

  /// Stable route identifier.
  String get id => _mailbox.id;

  /// Current route lifecycle.
  AudioRouteState get state => _mailbox.state;

  /// Current immutable counters.
  AudioRouteMetrics get metrics => _mailbox.metrics;

  /// Broadcast events produced by this route.
  Stream<AudioRouteEvent> get events => _mailbox.events;

  /// Completes when the route sink has been finalized and closed.
  Future<void> get done => _mailbox.done;

  /// Dynamically detaches this route.
  ///
  /// With [drain] true, accepted frames are delivered before the sink is
  /// finished. Otherwise buffered frames are discarded and the sink is aborted.
  Future<void> detach({bool drain = true}) => drain
      ? _mailbox.finish()
      : _mailbox.abort(
          failure: AudioFailure(
            code: 'route_detached',
            stage: AudioFailureStage.routing,
            message: 'Audio route "$id" was detached.',
          ),
        );
}

final class _RouteMailbox {
  _RouteMailbox({
    required this.id,
    required this.sink,
    required this.options,
    required this._emitToRouter,
    required this._onTerminal,
    required this._onDisposed,
  }) {
    handle = AudioRoute._(this);
  }

  final String id;
  final AudioSinkSession sink;
  final AudioRouteOptions options;
  final void Function(AudioRouteEvent) _emitToRouter;
  final void Function() _onTerminal;
  final void Function() _onDisposed;
  final ListQueue<AudioFrame> _queue = ListQueue<AudioFrame>();
  final StreamController<AudioRouteEvent> _events =
      StreamController<AudioRouteEvent>.broadcast(sync: true);
  final Completer<void> _done = Completer<void>();

  late final AudioRoute handle;
  AudioRouteState state = AudioRouteState.attached;
  Future<void>? _worker;
  Future<void>? _cleanupFuture;
  Future<void>? _sinkCloseFuture;
  Future<void>? _completionFuture;
  Completer<void>? _spaceAvailable;
  _GapAccumulator? _pendingGap;
  int _acceptedFrames = 0;
  int _deliveredFrames = 0;
  int _deliveredSampleFrames = 0;
  int _droppedFrames = 0;
  int _droppedSampleFrames = 0;
  int _highWaterMark = 0;
  int _queuedSampleFrames = 0;
  int _queuedSampleFramesHighWaterMark = 0;
  int _failureCount = 0;
  bool _accepting = true;
  bool _sinkFinishStarted = false;
  final AudioCancellationController _finishCancellation =
      AudioCancellationController();
  Completer<void>? _sinkFinishSettled;

  Stream<AudioRouteEvent> get events => _events.stream;
  Future<void> get done => _done.future;

  AudioRouteMetrics get metrics => AudioRouteMetrics(
    routeId: id,
    acceptedFrames: _acceptedFrames,
    deliveredFrames: _deliveredFrames,
    deliveredSampleFrames: _deliveredSampleFrames,
    droppedFrames: _droppedFrames,
    droppedSampleFrames: _droppedSampleFrames,
    currentDepth: _queue.length,
    highWaterMark: _highWaterMark,
    currentQueuedSampleFrames: _queuedSampleFrames,
    queuedSampleFramesHighWaterMark: _queuedSampleFramesHighWaterMark,
    failureCount: _failureCount,
  );

  void activate() {
    _emitState(AudioRouteState.attached);
  }

  Future<AudioDispatchOutcome> enqueue(AudioFrame frame) async {
    if (options.overflowPolicy != AudioOverflowPolicy.blockUpstream) {
      return enqueueRealtime(frame);
    }
    if (frame.frameCount > options.capacitySampleFrames) {
      unawaited(
        _fail(
          _overflowFailure(
            'Audio route "$id" received a frame larger than its sample bound.',
          ),
        ),
      );
      return AudioDispatchOutcome.routeFailed;
    }
    while (_accepting && !_canFit(frame)) {
      await _waitForSpace();
    }
    return _accept(frame);
  }

  /// Synchronous admission for realtime routers.
  ///
  /// This keeps the only pending audio in each route's bounded mailbox instead
  /// of building an unbounded chain of dispatch futures ahead of the routes.
  AudioDispatchOutcome enqueueRealtime(AudioFrame frame) {
    if (frame.frameCount > options.capacitySampleFrames) {
      switch (options.overflowPolicy) {
        case AudioOverflowPolicy.dropOldest:
        case AudioOverflowPolicy.dropNewest:
          _recordGap(frame);
          return AudioDispatchOutcome.dropped;
        case AudioOverflowPolicy.failRoute:
          unawaited(
            _fail(
              _overflowFailure(
                'Audio route "$id" received a frame larger than its sample '
                'bound.',
              ),
            ),
          );
          return AudioDispatchOutcome.routeFailed;
        case AudioOverflowPolicy.blockUpstream:
          throw StateError(
            'A realtime route cannot use blockUpstream admission.',
          );
      }
    }
    while (_accepting && !_canFit(frame)) {
      switch (options.overflowPolicy) {
        case AudioOverflowPolicy.dropOldest:
          final dropped = _removeFirst();
          _recordGap(dropped);
          continue;
        case AudioOverflowPolicy.dropNewest:
          _recordGap(frame);
          return AudioDispatchOutcome.dropped;
        case AudioOverflowPolicy.failRoute:
          final failure = _overflowFailure(
            'Audio route "$id" exceeded its bounded capacity.',
          );
          unawaited(_fail(failure));
          return AudioDispatchOutcome.routeFailed;
        case AudioOverflowPolicy.blockUpstream:
          throw StateError(
            'A realtime route cannot use blockUpstream admission.',
          );
      }
    }
    return _accept(frame);
  }

  AudioDispatchOutcome _accept(AudioFrame frame) {
    if (!_accepting) {
      return AudioDispatchOutcome.routeUnavailable;
    }

    _queue.addLast(frame);
    _queuedSampleFrames += frame.frameCount;
    _acceptedFrames += 1;
    if (_queue.length > _highWaterMark) {
      _highWaterMark = _queue.length;
    }
    if (_queuedSampleFrames > _queuedSampleFramesHighWaterMark) {
      _queuedSampleFramesHighWaterMark = _queuedSampleFrames;
    }
    _ensureWorker();
    return AudioDispatchOutcome.accepted;
  }

  Future<void> finish() {
    if (state == AudioRouteState.draining ||
        state == AudioRouteState.finished ||
        state == AudioRouteState.aborted ||
        state == AudioRouteState.failed) {
      return done;
    }
    _accepting = false;
    _onTerminal();
    _signalSpace();
    state = AudioRouteState.draining;
    _emitState(state);
    _ensureWorker();
    return done;
  }

  Future<void> abort({required AudioFailure failure}) {
    if (state == AudioRouteState.finished ||
        state == AudioRouteState.aborted ||
        state == AudioRouteState.failed) {
      return done;
    }
    _accepting = false;
    _onTerminal();
    _queue.clear();
    _queuedSampleFrames = 0;
    _signalSpace();
    state = AudioRouteState.aborted;
    _emitState(state);
    _finishCancellation.cancel(
      const AudioCancellation(reason: 'route_aborted'),
    );
    unawaited(_startAbortCleanup(failure));
    return done;
  }

  void _ensureWorker() {
    _worker ??= _runWorker();
  }

  Future<void> _runWorker() async {
    while (_queue.isNotEmpty && state != AudioRouteState.aborted) {
      var frame = _removeFirst();
      final pendingGap = _pendingGap;
      if (pendingGap != null && pendingGap.precedes(frame)) {
        _pendingGap = null;
        frame = frame.copyWith(
          discontinuity: pendingGap.mergedWith(frame.discontinuity),
        );
      }
      try {
        await sink.write(frame);
        _deliveredFrames += 1;
        _deliveredSampleFrames += frame.frameCount;
      } catch (error) {
        await _fail(
          AudioFailure(
            code: 'route_sink_write_failed',
            stage: AudioFailureStage.routing,
            message: 'The sink for audio route "$id" failed.',
            safeCause: error.runtimeType.toString(),
          ),
        );
        return;
      }
    }

    _worker = null;
    if (state == AudioRouteState.draining && _queue.isEmpty) {
      await _finishSink();
    } else if (_queue.isNotEmpty && state == AudioRouteState.attached) {
      _ensureWorker();
    }
  }

  Future<void> _finishSink() async {
    if (_sinkFinishStarted) {
      return;
    }
    _sinkFinishStarted = true;
    final Completer<void> finishSettled = Completer<void>();
    _sinkFinishSettled = finishSettled;
    try {
      await sink.finish(cancellationToken: _finishCancellation.token);
    } catch (error) {
      if (state == AudioRouteState.aborted || state == AudioRouteState.failed) {
        return;
      }
      final failure = AudioFailure(
        code: 'route_sink_finish_failed',
        stage: AudioFailureStage.routing,
        message: 'The sink for audio route "$id" could not be finalized.',
        safeCause: error.runtimeType.toString(),
      );
      _markFailed(failure);
      _finishCancellation.cancel(
        const AudioCancellation(reason: 'route_finish_failed'),
      );
      unawaited(_startAbortCleanup(failure));
      return;
    } finally {
      if (!finishSettled.isCompleted) {
        finishSettled.complete();
      }
    }

    if (state == AudioRouteState.aborted || state == AudioRouteState.failed) {
      return;
    }

    try {
      await _closeSink();
    } catch (error) {
      final failure = AudioFailure(
        code: 'route_sink_close_failed',
        stage: AudioFailureStage.routing,
        message: 'The sink for audio route "$id" could not be closed.',
        safeCause: error.runtimeType.toString(),
      );
      _markFailed(failure);
      await _completeRoute();
      return;
    }

    if (state == AudioRouteState.draining) {
      state = AudioRouteState.finished;
      _emitState(state);
      _emit(
        AudioRouteMetricsUpdated(
          routeId: id,
          timestamp: _now(),
          metrics: metrics,
        ),
      );
    }
    await _completeRoute();
  }

  Future<void> _fail(AudioFailure failure) {
    if (state == AudioRouteState.finished ||
        state == AudioRouteState.aborted ||
        state == AudioRouteState.failed) {
      return done;
    }
    _accepting = false;
    _onTerminal();
    _queue.clear();
    _queuedSampleFrames = 0;
    _signalSpace();
    _markFailed(failure);
    _finishCancellation.cancel(const AudioCancellation(reason: 'route_failed'));
    unawaited(_startAbortCleanup(failure));
    return done;
  }

  void _markFailed(AudioFailure failure) {
    if (state != AudioRouteState.failed) {
      _failureCount += 1;
      state = AudioRouteState.failed;
      _emit(AudioRouteFailed(routeId: id, timestamp: _now(), failure: failure));
      _emitState(state);
    }
  }

  Future<void> _startAbortCleanup(AudioFailure failure) =>
      _cleanupFuture ??= _abortAndClose(failure);

  Future<void> _abortAndClose(AudioFailure failure) async {
    Object? cleanupError;
    try {
      await sink.abort(failure: failure);
    } catch (error) {
      cleanupError = error;
    }
    final Completer<void>? finishSettled = _sinkFinishSettled;
    if (finishSettled != null) {
      await finishSettled.future;
    }
    try {
      await _closeSink();
    } catch (error) {
      cleanupError ??= error;
    }
    if (cleanupError != null) {
      _markFailed(
        AudioFailure(
          code: 'route_sink_cleanup_failed',
          stage: AudioFailureStage.routing,
          message: 'The sink for audio route "$id" could not be cleaned up.',
          safeCause: cleanupError.runtimeType.toString(),
        ),
      );
    }
    await _completeRoute();
  }

  Future<void> _closeSink() => _sinkCloseFuture ??= sink.close();

  Future<void> _completeRoute() => _completionFuture ??= _completeRouteOnce();

  Future<void> _completeRouteOnce() {
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
    _onDisposed();
    if (!_done.isCompleted) {
      _done.complete();
    }
    return Future<void>.value();
  }

  void _recordGap(AudioFrame frame) {
    _droppedFrames += 1;
    _droppedSampleFrames += frame.frameCount;
    _pendingGap = (_pendingGap ?? _GapAccumulator()).include(frame);
    _emit(
      AudioRouteGap(
        routeId: id,
        timestamp: _now(),
        firstSequence: frame.sequence,
        lastSequence: frame.sequence,
        firstSampleOffset: frame.sampleOffset,
        endSampleOffset: frame.endSampleOffset,
        droppedFrames: 1,
        droppedSampleFrames: frame.frameCount,
      ),
    );
  }

  Future<void> _waitForSpace() {
    final current = _spaceAvailable;
    if (current != null && !current.isCompleted) {
      return current.future;
    }
    final next = Completer<void>();
    _spaceAvailable = next;
    return next.future;
  }

  bool _canFit(AudioFrame frame) =>
      _queue.length < options.capacityFrames &&
      _queuedSampleFrames + frame.frameCount <= options.capacitySampleFrames;

  AudioFrame _removeFirst() {
    final AudioFrame frame = _queue.removeFirst();
    _queuedSampleFrames -= frame.frameCount;
    _signalSpace();
    return frame;
  }

  AudioFailure _overflowFailure(String message) => AudioFailure(
    code: 'route_overflow',
    stage: AudioFailureStage.routing,
    message: message,
  );

  void _signalSpace() {
    final waiter = _spaceAvailable;
    _spaceAvailable = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  void _emitState(AudioRouteState next) {
    _emit(AudioRouteStateChanged(routeId: id, timestamp: _now(), state: next));
  }

  void _emit(AudioRouteEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
    _emitToRouter(event);
  }
}

final class _GapAccumulator {
  const _GapAccumulator({
    this.frames = 0,
    this.sampleFrames = 0,
    this.previousSequence,
    this.lastSequence = -1,
    this.endSampleOffset = -1,
  });

  final int frames;
  final int sampleFrames;
  final int? previousSequence;
  final int lastSequence;
  final int endSampleOffset;

  _GapAccumulator include(AudioFrame frame) => _GapAccumulator(
    frames: frames + 1,
    sampleFrames: sampleFrames + frame.frameCount,
    previousSequence:
        previousSequence ?? (frame.sequence == 0 ? null : frame.sequence - 1),
    lastSequence: frame.sequence > lastSequence ? frame.sequence : lastSequence,
    endSampleOffset: frame.endSampleOffset > endSampleOffset
        ? frame.endSampleOffset
        : endSampleOffset,
  );

  bool precedes(AudioFrame frame) =>
      frame.sequence > lastSequence || frame.sampleOffset >= endSampleOffset;

  AudioDiscontinuity get discontinuity => AudioDiscontinuity(
    reason: AudioDiscontinuityReason.droppedFrames,
    droppedFrameCount: frames,
    droppedSampleFrameCount: sampleFrames,
    previousSequence: previousSequence,
    description: 'Frames were discarded by a bounded audio route.',
  );

  AudioDiscontinuity mergedWith(AudioDiscontinuity? source) {
    if (source == null) {
      return discontinuity;
    }
    return AudioDiscontinuity(
      reason: source.reason,
      droppedFrameCount: source.droppedFrameCount + frames,
      droppedSampleFrameCount: source.droppedSampleFrameCount + sampleFrames,
      previousSequence: previousSequence ?? source.previousSequence,
      description: source.description == null
          ? 'Frames were discarded by a bounded audio route.'
          : '${source.description} Frames were also discarded by a bounded '
                'audio route.',
    );
  }
}

final Stopwatch _monotonicClock = Stopwatch()..start();

Duration _now() => _monotonicClock.elapsed;
