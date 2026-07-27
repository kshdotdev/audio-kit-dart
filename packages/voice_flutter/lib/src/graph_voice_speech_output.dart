import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:audio_kit_graph/audio_kit_graph.dart';
import 'package:voice_core/voice_core.dart';

/// Builds optional output routes for one synthesized source.
///
/// The builder runs once per [GraphVoiceSpeechOutput.play] call. Returning new
/// sink objects is useful for per-utterance files, while reusable sinks such as
/// meters may return the same object for every call.
typedef VoiceSpeechOutputRouteBuilder =
    FutureOr<Iterable<VoiceSpeechOutputRoute>> Function(AudioFormat format);

/// One optional bounded branch attached beside device playback.
final class VoiceSpeechOutputRoute {
  /// Creates an output branch.
  VoiceSpeechOutputRoute({
    required this.id,
    required this.sink,
    required this.options,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be empty.');
    }
  }

  /// Stable route identifier for this playback operation.
  final String id;

  /// Sink prepared with the synthesized source format.
  final AudioSink sink;

  /// Explicit bounded-mailbox behavior for this branch.
  final AudioRouteOptions options;
}

/// Routes synthesized audio into device playback and optional sibling sinks.
///
/// The output owns each prepared source and sink session, but not the reusable
/// [playbackSink] or sinks returned by [extraRoutes]. A play call completes only
/// after the finite source terminates, every accepted playback frame drains,
/// and all prepared sessions close.
///
/// Overlapping play calls use latest-call-wins semantics. The previous source
/// and playback session are aborted and fully joined before the next source is
/// prepared, preventing stale completion from stopping newer audio.
final class GraphVoiceSpeechOutput implements VoiceSpeechOutput {
  /// Creates a graph-backed voice output.
  GraphVoiceSpeechOutput({
    required this.playbackSink,
    this.extraRoutes,
    this.playbackRouteId = 'playback',
    this.playbackOptions,
    this.defaultCapacityFrames = 64,
    this.defaultCapacitySampleFrames = 384000,
  }) {
    if (playbackRouteId.trim().isEmpty) {
      throw ArgumentError.value(
        playbackRouteId,
        'playbackRouteId',
        'Must not be empty.',
      );
    }
    if (defaultCapacityFrames <= 0) {
      throw ArgumentError.value(
        defaultCapacityFrames,
        'defaultCapacityFrames',
        'Must be positive.',
      );
    }
    if (defaultCapacitySampleFrames <= 0) {
      throw ArgumentError.value(
        defaultCapacitySampleFrames,
        'defaultCapacitySampleFrames',
        'Must be positive.',
      );
    }
  }

  /// Device playback sink, normally a `FlutterAudioPlaybackSink`.
  final AudioSink playbackSink;

  /// Optional per-play route builder for recording, metering, or analysis.
  final VoiceSpeechOutputRouteBuilder? extraRoutes;

  /// Stable ID assigned to the required playback route.
  final String playbackRouteId;

  /// Explicit playback mailbox behavior.
  ///
  /// When omitted, pausable sources use bounded upstream blocking and
  /// non-pausable sources use a bounded fail-loud route.
  final AudioRouteOptions? playbackOptions;

  /// Default frame bound used when [playbackOptions] is omitted.
  final int defaultCapacityFrames;

  /// Default sample-frame bound used when [playbackOptions] is omitted.
  final int defaultCapacitySampleFrames;

  _PlaybackOperation? _active;
  Future<void>? _closeFuture;
  var _nextOperationId = 0;
  var _closing = false;

  /// Whether close has been requested.
  bool get isClosed => _closing;

  @override
  Future<void> play(
    AudioSource source, {
    required AudioCancellationToken cancellationToken,
  }) {
    if (_closing) {
      throw StateError('Voice speech output is closed.');
    }
    cancellationToken.throwIfCancelled();

    final _PlaybackOperation? previous = _active;
    final _PlaybackOperation operation = _PlaybackOperation(
      id: ++_nextOperationId,
      source: source,
      externalCancellation: cancellationToken,
    );
    _active = operation;

    final Future<void> previousAbort;
    if (previous == null) {
      previousAbort = Future<void>.value();
    } else {
      previousAbort = previous.requestAbort(
        const AudioCancellation(reason: 'playback_superseded'),
      );
    }

    late final Future<void> tracked;
    tracked =
        _playAfterPrevious(
          operation,
          previous: previous,
          previousAbort: previousAbort,
        ).whenComplete(() {
          operation.dispose();
          if (identical(_active, operation)) {
            _active = null;
          }
        });
    operation.done = tracked;
    return tracked;
  }

  Future<void> _playAfterPrevious(
    _PlaybackOperation operation, {
    required _PlaybackOperation? previous,
    required Future<void> previousAbort,
  }) async {
    Object? abortFailure;
    StackTrace? abortStackTrace;
    try {
      await previousAbort;
    } catch (error, stackTrace) {
      abortFailure = error;
      abortStackTrace = stackTrace;
    }
    if (previous != null) {
      try {
        await previous.done;
      } catch (_) {
        // The previous play caller observes its operational result. Waiting
        // here is solely the ownership barrier before a new session starts.
      }
    }
    if (abortFailure != null) {
      Error.throwWithStackTrace(
        abortFailure,
        abortStackTrace ?? StackTrace.current,
      );
    }
    _ensureCurrent(operation);
    await _run(operation);
  }

  Future<void> _run(_PlaybackOperation operation) async {
    AudioHub? hub;
    StreamSubscription<AudioSessionStatus>? sourceStatuses;
    StreamSubscription<AudioRouteEvent>? playbackEvents;
    Object? primaryError;
    StackTrace? primaryStackTrace;
    var completedGracefully = false;

    try {
      final AudioHub preparedHub = await AudioHub.prepare(
        operation.source,
        cancellationToken: operation.cancellation.token,
      );
      hub = preparedHub;
      operation.hub = preparedHub;
      _ensureCurrent(operation);

      final List<VoiceSpeechOutputRoute> additionalRoutes =
          await _buildExtraRoutes(preparedHub.source.format);
      _validateRouteIds(additionalRoutes);
      _ensureCurrent(operation);

      final AudioRoute playbackRoute = await preparedHub.attach(
        id: playbackRouteId,
        sink: playbackSink,
        options: _playbackRouteOptions(preparedHub.source.capabilities),
        cancellationToken: operation.cancellation.token,
      );
      operation.playbackRoute = playbackRoute;

      AudioFailure? playbackFailure;
      playbackEvents = playbackRoute.events.listen((AudioRouteEvent event) {
        if (event is AudioRouteFailed) {
          playbackFailure ??= event.failure;
        }
      });

      for (final VoiceSpeechOutputRoute route in additionalRoutes) {
        await preparedHub.attach(
          id: route.id,
          sink: route.sink,
          options: route.options,
          cancellationToken: operation.cancellation.token,
        );
        _ensureCurrent(operation);
      }

      final _SourceTerminalWatcher terminal = _SourceTerminalWatcher(
        preparedHub.source,
      );
      sourceStatuses = terminal.subscription;

      await preparedHub.start(cancellationToken: operation.cancellation.token);
      _ensureCurrent(operation);

      final _PlaybackCompletion completion = await _waitForCompletion(
        operation: operation,
        hub: preparedHub,
        route: playbackRoute,
        terminal: terminal,
      );
      _ensureCurrent(operation);
      _throwForSourceCompletion(completion, preparedHub);

      await preparedHub.router.finish();
      await playbackRoute.done;
      _ensureCurrent(operation);
      if (playbackFailure != null) {
        throw playbackFailure!;
      }
      if (playbackRoute.state != AudioRouteState.finished) {
        throw _playbackRouteFailure(playbackRoute.state);
      }
      completedGracefully = true;
    } catch (error, stackTrace) {
      primaryError = error;
      primaryStackTrace = stackTrace;
    }

    final _FirstError cleanup = _FirstError();
    await cleanup.capture(() async => sourceStatuses?.cancel());
    await cleanup.capture(() async => playbackEvents?.cancel());
    if (hub != null) {
      if (!completedGracefully) {
        final AudioFailure? failure = primaryError is AudioFailure
            ? primaryError
            : null;
        await cleanup.capture(() => hub!.abort(failure: failure));
      }
      await cleanup.capture(hub.close);
    }

    if (primaryError != null) {
      Error.throwWithStackTrace(
        primaryError,
        primaryStackTrace ?? StackTrace.current,
      );
    }
    cleanup.throwIfPresent();
  }

  Future<List<VoiceSpeechOutputRoute>> _buildExtraRoutes(
    AudioFormat format,
  ) async {
    final VoiceSpeechOutputRouteBuilder? builder = extraRoutes;
    if (builder == null) {
      return <VoiceSpeechOutputRoute>[];
    }
    final Iterable<VoiceSpeechOutputRoute> routes = await builder(format);
    return List<VoiceSpeechOutputRoute>.of(routes);
  }

  void _validateRouteIds(List<VoiceSpeechOutputRoute> routes) {
    final Set<String> ids = <String>{playbackRouteId};
    for (final VoiceSpeechOutputRoute route in routes) {
      if (!ids.add(route.id)) {
        throw ArgumentError.value(
          route.id,
          'extraRoutes',
          'Output route IDs must be unique and must not use '
              '"$playbackRouteId".',
        );
      }
    }
  }

  AudioRouteOptions _playbackRouteOptions(
    AudioSourceCapabilities capabilities,
  ) {
    final AudioRouteOptions? configured = playbackOptions;
    if (configured != null) {
      return configured;
    }
    if (capabilities.supportsPause) {
      return AudioRouteOptions.blocking(
        capacityFrames: defaultCapacityFrames,
        capacitySampleFrames: defaultCapacitySampleFrames,
      );
    }
    return AudioRouteOptions.lossless(
      capacityFrames: defaultCapacityFrames,
      capacitySampleFrames: defaultCapacitySampleFrames,
    );
  }

  Future<_PlaybackCompletion> _waitForCompletion({
    required _PlaybackOperation operation,
    required AudioHub hub,
    required AudioRoute route,
    required _SourceTerminalWatcher terminal,
  }) async {
    final AudioSessionStatus current = hub.source.status;
    if (current.isTerminal) {
      return _PlaybackCompletion.source(current);
    }
    return Future.any<_PlaybackCompletion>(<Future<_PlaybackCompletion>>[
      terminal.done,
      route.done.then(
        (_) => _PlaybackCompletion.route(route.state, hub.source.status),
      ),
      operation.cancellation.token.whenCancelled.then(
        _PlaybackCompletion.cancelled,
      ),
    ]);
  }

  void _throwForSourceCompletion(_PlaybackCompletion completion, AudioHub hub) {
    final AudioCancellation? cancellation = completion.cancellation;
    if (cancellation != null) {
      throw AudioCancelledException(cancellation);
    }

    final Object? statusStreamError = completion.statusStreamError;
    if (statusStreamError != null) {
      throw AudioFailure(
        code: 'voice_output_source_status_failed',
        stage: AudioFailureStage.playback,
        message: 'Synthesized audio status monitoring failed.',
        retryable: true,
        safeCause: statusStreamError.runtimeType.toString(),
      );
    }

    final AudioSessionStatus status =
        completion.sourceStatus ?? hub.source.status;
    if (status.state == AudioSessionState.finished) {
      return;
    }
    final AudioRouteState? routeState = completion.routeState;
    if (status.state == AudioSessionState.failed && status.failure != null) {
      throw status.failure!;
    }
    if (routeState != null &&
        routeState != AudioRouteState.finished &&
        routeState != AudioRouteState.draining) {
      throw _playbackRouteFailure(routeState);
    }
    if (hub.state == AudioSessionState.failed) {
      throw AudioFailure(
        code: 'voice_output_source_failed',
        stage: AudioFailureStage.playback,
        message: 'Synthesized audio failed during playback.',
        retryable: true,
        safeCause: status.failure?.code,
      );
    }
    throw AudioFailure(
      code: switch (status.state) {
        AudioSessionState.aborted => 'voice_output_source_aborted',
        AudioSessionState.closed => 'voice_output_source_closed',
        _ => 'voice_output_source_ended_unexpectedly',
      },
      stage: AudioFailureStage.playback,
      message: 'Synthesized audio ended before playback completed.',
      retryable: true,
      safeCause: status.failure?.code,
    );
  }

  AudioFailure _playbackRouteFailure(AudioRouteState state) => AudioFailure(
    code: 'voice_output_playback_route_failed',
    stage: AudioFailureStage.playback,
    message: 'Synthesized audio could not be delivered to playback.',
    retryable: true,
    safeCause: state.name,
  );

  void _ensureCurrent(_PlaybackOperation operation) {
    operation.cancellation.token.throwIfCancelled();
    if (_closing || !identical(_active, operation)) {
      throw const AudioCancelledException(
        AudioCancellation(reason: 'playback_stale'),
      );
    }
  }

  @override
  Future<void> interrupt() async {
    final _PlaybackOperation? operation = _active;
    if (operation == null) {
      return;
    }
    final Future<void> abort = operation.requestAbort(
      const AudioCancellation(reason: 'playback_interrupted'),
    );
    await abort;
    try {
      await operation.done;
    } on AudioCancelledException {
      // Expected result of interrupting the active play call.
    }
  }

  @override
  Future<void> close() {
    final Future<void>? existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closing = true;
    final _PlaybackOperation? operation = _active;
    final Future<void> abort =
        operation?.requestAbort(
          const AudioCancellation(reason: 'voice_output_closed'),
        ) ??
        Future<void>.value();
    return _closeFuture = _close(operation, abort);
  }

  Future<void> _close(_PlaybackOperation? operation, Future<void> abort) async {
    final _FirstError errors = _FirstError();
    await errors.capture(() async => abort);
    if (operation != null) {
      try {
        await operation.done;
      } on AudioCancelledException {
        // Expected close result for the in-flight play call.
      } catch (error, stackTrace) {
        errors.add(error, stackTrace);
      }
    }
    errors.throwIfPresent();
  }
}

final class _PlaybackOperation {
  _PlaybackOperation({
    required this.id,
    required this.source,
    required AudioCancellationToken externalCancellation,
  }) {
    _externalRegistration = externalCancellation.register((
      AudioCancellation reason,
    ) {
      final Future<void> abort = requestAbort(reason);
      unawaited(abort.catchError((Object _) {}));
    });
  }

  final int id;
  final AudioSource source;
  final AudioCancellationController cancellation =
      AudioCancellationController();
  late final Future<void> done;
  AudioHub? hub;
  AudioRoute? playbackRoute;
  late final AudioCancellationRegistration _externalRegistration;
  Future<void>? _abortFuture;

  void dispose() {
    _externalRegistration.dispose();
    hub = null;
    playbackRoute = null;
  }

  Future<void> requestAbort(AudioCancellation reason) {
    cancellation.cancel(reason);
    final AudioHub? currentHub = hub;
    if (currentHub == null) {
      return Future<void>.value();
    }
    return _abortFuture ??= currentHub.abort();
  }
}

final class _SourceTerminalWatcher {
  _SourceTerminalWatcher(AudioSourceSession source) {
    subscription = source.statuses.listen(
      (AudioSessionStatus status) {
        if (status.isTerminal && !_done.isCompleted) {
          _done.complete(_PlaybackCompletion.source(status));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_done.isCompleted) {
          _done.complete(_PlaybackCompletion.statusError(error));
        }
      },
      onDone: () {
        if (_done.isCompleted) {
          return;
        }
        final AudioSessionStatus current = source.status;
        if (current.isTerminal) {
          _done.complete(_PlaybackCompletion.source(current));
        } else {
          _done.complete(
            _PlaybackCompletion.statusError(
              StateError('Source status stream closed before termination.'),
            ),
          );
        }
      },
    );
    final AudioSessionStatus current = source.status;
    if (current.isTerminal && !_done.isCompleted) {
      _done.complete(_PlaybackCompletion.source(current));
    }
  }

  final Completer<_PlaybackCompletion> _done = Completer<_PlaybackCompletion>();
  // Cancelled by GraphVoiceSpeechOutput._run after every terminal path.
  // ignore: cancel_subscriptions
  late final StreamSubscription<AudioSessionStatus> subscription;

  Future<_PlaybackCompletion> get done => _done.future;
}

final class _PlaybackCompletion {
  const _PlaybackCompletion._({
    this.sourceStatus,
    this.routeState,
    this.cancellation,
    this.statusStreamError,
  });

  factory _PlaybackCompletion.cancelled(AudioCancellation cancellation) =>
      _PlaybackCompletion._(cancellation: cancellation);

  factory _PlaybackCompletion.route(
    AudioRouteState routeState,
    AudioSessionStatus sourceStatus,
  ) =>
      _PlaybackCompletion._(routeState: routeState, sourceStatus: sourceStatus);

  factory _PlaybackCompletion.source(AudioSessionStatus sourceStatus) =>
      _PlaybackCompletion._(sourceStatus: sourceStatus);

  factory _PlaybackCompletion.statusError(Object error) =>
      _PlaybackCompletion._(statusStreamError: error);

  final AudioSessionStatus? sourceStatus;
  final AudioRouteState? routeState;
  final AudioCancellation? cancellation;
  final Object? statusStreamError;
}

final class _FirstError {
  Object? error;
  StackTrace? stackTrace;

  void add(Object value, StackTrace trace) {
    error ??= value;
    stackTrace ??= trace;
  }

  Future<void> capture(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (value, trace) {
      add(value, trace);
    }
  }

  void throwIfPresent() {
    final Object? value = error;
    if (value != null) {
      Error.throwWithStackTrace(value, stackTrace ?? StackTrace.current);
    }
  }
}
