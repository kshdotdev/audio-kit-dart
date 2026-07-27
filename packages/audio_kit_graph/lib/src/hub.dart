import 'dart:async';

import 'package:audio_core/audio_core.dart';

import 'options.dart';
import 'router.dart';

/// Owns one source session and its independent bounded fan-out router.
///
/// Applications normally create one hub for microphone audio and another for
/// system audio. Tracks are never merged implicitly; use audio_processing's
/// explicit synchronizer/mixer when a chronological or mixed stream is needed.
final class AudioHub {
  AudioHub._({required this.source, required this.router});

  /// Prepares [source] without starting it, allowing routes and listeners to
  /// attach before the first frame or health event.
  static Future<AudioHub> prepare(
    AudioSource audioSource, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final AudioSourceSession session = await audioSource.prepare(
      cancellationToken: cancellationToken,
    );
    try {
      cancellationToken?.throwIfCancelled();
      return AudioHub._(
        source: session,
        router: AudioRouter(
          format: session.format,
          upstreamPausable: session.capabilities.supportsPause,
        ),
      );
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  /// Prepared source owned by this hub.
  final AudioSourceSession source;

  /// Dynamic bounded route graph owned by this hub.
  final AudioRouter router;

  AudioSessionState _state = AudioSessionState.prepared;
  StreamSubscription<AudioFrame>? _framesSubscription;
  StreamSubscription<AudioSessionStatus>? _statusSubscription;
  Future<void>? _startFuture;
  Future<void>? _sourceFinishFuture;
  Future<void>? _stopFuture;
  Future<void>? _abortFuture;
  Future<void>? _closeFuture;

  /// Current hub lifecycle.
  AudioSessionState get state => _state;

  /// Prepares and attaches [sink], transferring session ownership to the route.
  Future<AudioRoute> attach({
    required String id,
    required AudioSink sink,
    required AudioRouteOptions options,
    AudioCancellationToken? cancellationToken,
  }) async {
    _ensureAttachable();
    cancellationToken?.throwIfCancelled();
    final AudioSinkSession session = await sink.prepare(
      source.format,
      cancellationToken: cancellationToken,
    );
    try {
      cancellationToken?.throwIfCancelled();
      _ensureAttachable();
      return router.attach(id: id, sink: session, options: options);
    } catch (_) {
      try {
        await session.abort();
      } finally {
        await session.close();
      }
      rethrow;
    }
  }

  /// Attaches an already prepared session and transfers its ownership.
  AudioRoute attachPrepared({
    required String id,
    required AudioSinkSession sink,
    required AudioRouteOptions options,
  }) {
    _ensureAttachable();
    return router.attach(id: id, sink: sink, options: options);
  }

  /// Subscribes to source frames before starting native or synthesized audio.
  Future<void> start({AudioCancellationToken? cancellationToken}) =>
      _startFuture ??= _start(cancellationToken);

  Future<void> _start(AudioCancellationToken? cancellationToken) async {
    if (_state == AudioSessionState.active) {
      return;
    }
    if (_state != AudioSessionState.prepared) {
      throw StateError('An audio hub can only start from prepared state.');
    }
    cancellationToken?.throwIfCancelled();
    _state = AudioSessionState.starting;
    _statusSubscription = source.statuses.listen(
      _onSourceStatus,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(_fail(error, stackTrace));
      },
      onDone: _onSourceStatusesDone,
    );
    _framesSubscription = source.frames.listen(
      _onFrame,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(_fail(error, stackTrace));
      },
      onDone: _onFramesDone,
    );
    try {
      await source.start(cancellationToken: cancellationToken);
      cancellationToken?.throwIfCancelled();
      if (_state == AudioSessionState.starting) {
        _state = AudioSessionState.active;
      }
    } on AudioCancelledException {
      await abort();
      rethrow;
    } catch (error, stackTrace) {
      final AudioFailure failure = _asHubFailure(error);
      await _fail(failure, stackTrace);
      throw failure;
    }
  }

  void _onFrame(AudioFrame frame) {
    if (_state != AudioSessionState.active &&
        _state != AudioSessionState.starting &&
        _state != AudioSessionState.finishing) {
      return;
    }
    if (source.capabilities.supportsPause) {
      _framesSubscription?.pause();
      unawaited(_forwardWithSourceBackpressure(frame));
    } else {
      unawaited(_forwardLive(frame));
    }
  }

  Future<void> _forwardLive(AudioFrame frame) async {
    try {
      await router.add(frame);
    } catch (error, stackTrace) {
      if (_state != AudioSessionState.finishing &&
          _state != AudioSessionState.finished &&
          _state != AudioSessionState.aborted &&
          _state != AudioSessionState.failed &&
          _state != AudioSessionState.closed) {
        await _fail(error, stackTrace);
      }
    }
  }

  Future<void> _forwardWithSourceBackpressure(AudioFrame frame) async {
    try {
      await source.pause();
      await router.add(frame);
      if (_state == AudioSessionState.active ||
          _state == AudioSessionState.starting) {
        await source.resume();
      }
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
    } finally {
      _framesSubscription?.resume();
    }
  }

  void _onFramesDone() {
    final AudioSessionStatus sourceStatus = source.status;
    if (sourceStatus.state == AudioSessionState.failed) {
      unawaited(
        _fail(
          sourceStatus.failure ?? _unexpectedSourceFailure('source_failed'),
          StackTrace.current,
        ),
      );
    } else if (sourceStatus.state == AudioSessionState.finished) {
      unawaited(_finishFromSource());
    }
    // Sources normally close their frame stream immediately before publishing
    // a terminal status. Waiting for that status prevents a native fail-capture
    // end-of-stream marker from being mistaken for graceful completion.
  }

  void _onSourceStatus(AudioSessionStatus status) {
    switch (status.state) {
      case AudioSessionState.finished:
        unawaited(_finishFromSource());
      case AudioSessionState.failed:
        unawaited(
          _fail(
            status.failure ?? _unexpectedSourceFailure('source_failed'),
            StackTrace.current,
          ),
        );
      case AudioSessionState.aborted:
        if (_state != AudioSessionState.aborted &&
            _state != AudioSessionState.failed &&
            _state != AudioSessionState.closed) {
          unawaited(
            _fail(
              status.failure ?? _unexpectedSourceFailure('source_aborted'),
              StackTrace.current,
            ),
          );
        }
      case AudioSessionState.closed:
        if (_state != AudioSessionState.closed &&
            _state != AudioSessionState.finished &&
            _state != AudioSessionState.aborted &&
            _state != AudioSessionState.failed) {
          unawaited(
            _fail(
              _unexpectedSourceFailure('source_closed'),
              StackTrace.current,
            ),
          );
        }
      case AudioSessionState.prepared:
      case AudioSessionState.starting:
      case AudioSessionState.active:
      case AudioSessionState.paused:
      case AudioSessionState.finishing:
        break;
    }
  }

  void _onSourceStatusesDone() {
    if (_state == AudioSessionState.active ||
        _state == AudioSessionState.starting) {
      unawaited(
        _fail(
          _unexpectedSourceFailure('source_status_stream_closed'),
          StackTrace.current,
        ),
      );
    }
  }

  AudioFailure _unexpectedSourceFailure(String code) => AudioFailure(
    code: code,
    stage: AudioFailureStage.routing,
    message: 'The audio source terminated unexpectedly.',
    retryable: true,
  );

  Future<void> _finishFromSource() =>
      _sourceFinishFuture ??= _finishFromSourceOnce();

  Future<void> _finishFromSourceOnce() async {
    if (_state != AudioSessionState.active &&
        _state != AudioSessionState.starting &&
        _state != AudioSessionState.finishing) {
      return;
    }
    _state = AudioSessionState.finishing;
    try {
      await router.finish();
      if (_state == AudioSessionState.finishing) {
        _state = AudioSessionState.finished;
      }
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
    }
  }

  /// Gracefully stops capture/synthesis, drains routes, and finalizes sinks.
  Future<void> stop({AudioCancellationToken? cancellationToken}) =>
      _stopFuture ??= _stop(cancellationToken);

  Future<void> _stop(AudioCancellationToken? cancellationToken) async {
    if (_state == AudioSessionState.finished) {
      return;
    }
    if (_state == AudioSessionState.prepared) {
      _state = AudioSessionState.finishing;
      await router.finish();
      _state = AudioSessionState.finished;
      return;
    }
    if (_state != AudioSessionState.active &&
        _state != AudioSessionState.starting &&
        _state != AudioSessionState.finishing) {
      return;
    }
    cancellationToken?.throwIfCancelled();
    _state = AudioSessionState.finishing;
    try {
      await source.stop(cancellationToken: cancellationToken);
      await router.finish();
      await _framesSubscription?.cancel();
      _framesSubscription = null;
      cancellationToken?.throwIfCancelled();
      if (_state == AudioSessionState.finishing) {
        _state = AudioSessionState.finished;
      }
    } on AudioCancelledException {
      await abort();
      rethrow;
    } catch (error, stackTrace) {
      final AudioFailure failure = _asHubFailure(error);
      await _fail(failure, stackTrace);
      throw failure;
    }
  }

  /// Immediately aborts the source and every route.
  Future<void> abort({AudioFailure? failure}) =>
      _abortFuture ??= _abort(failure);

  Future<void> _abort(AudioFailure? failure) async {
    if (_state == AudioSessionState.aborted ||
        _state == AudioSessionState.failed ||
        _state == AudioSessionState.closed) {
      return;
    }
    final AudioFailure resolved =
        failure ??
        AudioFailure(
          code: 'hub_aborted',
          stage: AudioFailureStage.routing,
          message: 'The audio hub was aborted.',
        );
    _state = failure == null
        ? AudioSessionState.aborted
        : AudioSessionState.failed;
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await Future.wait<void>(<Future<void>>[
        source.abort(failure: resolved),
        router.abort(failure: resolved),
      ]);
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await _framesSubscription?.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _framesSubscription = null;
    try {
      await _statusSubscription?.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _statusSubscription = null;
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }

  Future<void> _fail(Object error, StackTrace stackTrace) async {
    if (_state == AudioSessionState.failed ||
        _state == AudioSessionState.aborted ||
        _state == AudioSessionState.closed) {
      return;
    }
    final AudioFailure failure = _asHubFailure(error);
    try {
      await abort(failure: failure);
    } on Object {
      // Preserve the stable source failure. close() retries every independent
      // resource cleanup path and can surface a cleanup-specific error.
    }
  }

  AudioFailure _asHubFailure(Object error) => error is AudioFailure
      ? error
      : AudioFailure(
          code: 'hub_source_failed',
          stage: AudioFailureStage.routing,
          message: 'The audio source or hub failed.',
          retryable: true,
          safeCause: error.runtimeType.toString(),
        );

  /// Deterministically finalizes and releases every owned resource.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    if (_state == AudioSessionState.active ||
        _state == AudioSessionState.starting ||
        _state == AudioSessionState.finishing) {
      try {
        await stop();
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    } else if (_state == AudioSessionState.prepared) {
      try {
        await router.finish();
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    }
    try {
      await _framesSubscription?.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _framesSubscription = null;
    try {
      await _statusSubscription?.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _statusSubscription = null;
    try {
      await router.close();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await source.close();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _state = AudioSessionState.closed;
    if (firstError != null) {
      final AudioFailure failure = _asHubFailure(firstError);
      Error.throwWithStackTrace(failure, firstStackTrace ?? StackTrace.current);
    }
  }

  void _ensureAttachable() {
    if (_state == AudioSessionState.finishing ||
        _state == AudioSessionState.finished ||
        _state == AudioSessionState.aborted ||
        _state == AudioSessionState.failed ||
        _state == AudioSessionState.closed) {
      throw StateError('Cannot attach a route to a terminal audio hub.');
    }
  }
}
