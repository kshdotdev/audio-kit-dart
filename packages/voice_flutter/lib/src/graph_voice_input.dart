import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:audio_kit_graph/audio_kit_graph.dart';
import 'package:speech_core/speech_core.dart';
import 'package:voice_core/voice_core.dart';

/// Builds optional sibling routes for one voice capture session.
///
/// The builder runs once per successful [GraphVoiceInput.start] preparation,
/// after the capture format is known and before the source starts. Returning
/// fresh sinks is useful for per-session recordings, while reusable meters or
/// analysis sinks may be returned on every call.
typedef VoiceInputRouteBuilder =
    FutureOr<Iterable<VoiceInputRoute>> Function(AudioFormat format);

/// One optional bounded branch attached beside the required STT and VAD routes.
final class VoiceInputRoute {
  /// Creates an optional voice-input branch.
  VoiceInputRoute({
    required this.id,
    required this.sink,
    required this.options,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be empty.');
    }
  }

  /// Stable route identifier for this capture session.
  final String id;

  /// Sink prepared with the actual capture format.
  final AudioSink sink;

  /// Explicit bounded-mailbox behavior for this branch.
  final AudioRouteOptions options;
}

/// Lifecycle of a [GraphVoiceInput].
enum GraphVoiceInputState {
  /// No capture session is allocated.
  idle,

  /// Capture and provider sessions are being prepared.
  starting,

  /// Capture and VAD are active.
  active,

  /// The current graph is being drained or aborted.
  stopping,

  /// A required capture, STT, or VAD branch failed.
  failed,

  /// All resources and observer streams have been released.
  closed,
}

/// Provider-neutral VAD settings used by [GraphVoiceInput].
final class GraphVoiceActivityOptions {
  /// Creates validated voice-activity settings.
  GraphVoiceActivityOptions({
    this.startThreshold = 0.6,
    this.endThreshold = 0.4,
    this.minimumSpeech = const Duration(milliseconds: 100),
    this.minimumSilence = const Duration(milliseconds: 300),
    this.providerOptions,
  }) {
    if (!startThreshold.isFinite || startThreshold < 0 || startThreshold > 1) {
      throw ArgumentError.value(
        startThreshold,
        'startThreshold',
        'Must be between zero and one.',
      );
    }
    if (!endThreshold.isFinite || endThreshold < 0 || endThreshold > 1) {
      throw ArgumentError.value(
        endThreshold,
        'endThreshold',
        'Must be between zero and one.',
      );
    }
    if (minimumSpeech <= Duration.zero) {
      throw ArgumentError.value(
        minimumSpeech,
        'minimumSpeech',
        'Must be positive.',
      );
    }
    if (minimumSilence.isNegative) {
      throw ArgumentError.value(
        minimumSilence,
        'minimumSilence',
        'Must not be negative.',
      );
    }
  }

  /// Probability required to enter the speaking state.
  final double startThreshold;

  /// Probability below which speech may end.
  final double endThreshold;

  /// Required speech duration before a start event.
  final Duration minimumSpeech;

  /// Required silence before an end event.
  final Duration minimumSilence;

  /// Typed adapter-specific options, when the selected provider needs them.
  final SpeechProviderOptions? providerOptions;
}

/// A graph-backed [VoiceInput] that shares one capture between STT and VAD.
///
/// The input owns every prepared source and provider session it creates, but
/// borrows [source], [streamingSpeechToText], and [voiceActivityDetection].
/// Providers are intentionally not closed because the same provider may also
/// serve batch recognition, end-of-utterance detection, or synthesis.
///
/// Gating recognition aborts and detaches its lossless route. Re-enabling it
/// prepares a fresh session, subscribes to results, and only then attaches the
/// replacement route. Capture and VAD stay active throughout, so VAD can
/// detect barge-in while synthesized speech is playing.
final class GraphVoiceInput implements VoiceInput {
  /// Creates a reusable provider-neutral voice input.
  GraphVoiceInput({
    required this.source,
    required this.streamingSpeechToText,
    required this.voiceActivityDetection,
    SpeechRecognitionOptions? recognitionOptions,
    GraphVoiceActivityOptions? voiceActivityOptions,
    this.extraRoutes,
    int recognitionQueueCapacityFrames = 64,
    int recognitionQueueCapacitySampleFrames = 384000,
    int voiceActivityQueueCapacityFrames = 64,
    int voiceActivityQueueCapacitySampleFrames = 384000,
  }) : recognitionOptions = recognitionOptions ?? SpeechRecognitionOptions(),
       voiceActivityOptions =
           voiceActivityOptions ?? GraphVoiceActivityOptions(),
       _recognitionRouteOptions = AudioRouteOptions.lossless(
         capacityFrames: recognitionQueueCapacityFrames,
         capacitySampleFrames: recognitionQueueCapacitySampleFrames,
       ),
       _voiceActivityRouteOptions = AudioRouteOptions.lossless(
         capacityFrames: voiceActivityQueueCapacityFrames,
         capacitySampleFrames: voiceActivityQueueCapacitySampleFrames,
       );

  /// Capture source prepared once for each call to [start].
  final AudioSource source;

  /// Borrowed streaming recognizer.
  final StreamingSpeechToTextProvider streamingSpeechToText;

  /// Borrowed VAD provider.
  final VoiceActivityDetectionProvider voiceActivityDetection;

  /// Recognition configuration applied to every fresh STT session.
  final SpeechRecognitionOptions recognitionOptions;

  /// VAD configuration applied to each capture session.
  final GraphVoiceActivityOptions voiceActivityOptions;

  /// Optional per-session routes for recording, metering, or analysis.
  ///
  /// Once attached, failures on these routes remain isolated by [AudioRouter].
  /// Only the reserved STT and VAD routes are required input failures.
  final VoiceInputRouteBuilder? extraRoutes;

  /// Route ID reserved for the required streaming recognizer.
  static const String recognitionRouteId = 'voice-primary-stt';

  /// Route ID reserved for the required voice-activity detector.
  static const String voiceActivityRouteId = 'voice-vad';

  final AudioRouteOptions _recognitionRouteOptions;
  final AudioRouteOptions _voiceActivityRouteOptions;
  final StreamController<SpeechRecognitionEvent> _transcriptController =
      StreamController<SpeechRecognitionEvent>.broadcast(sync: true);
  final StreamController<VoiceActivityEvent> _voiceActivityController =
      StreamController<VoiceActivityEvent>.broadcast(sync: true);

  Future<void> _operationTail = Future<void>.value();
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  Future<void>? _closeFuture;
  GraphVoiceInputState _state = GraphVoiceInputState.idle;
  AudioHub? _hub;
  AudioCancellationController? _sessionCancellation;
  AudioCancellationRegistration? _externalCancellationRegistration;
  AudioCancellationController? _preparingRecognitionCancellation;
  _RecognitionBranch? _recognitionBranch;
  _VoiceActivityBranch? _voiceActivityBranch;
  StreamSubscription<AudioRouteEvent>? _routerEvents;
  StreamSubscription<AudioSessionStatus>? _sourceStatuses;
  bool _recognitionDesired = true;
  bool _failureReported = false;
  bool _closeRequested = false;
  int _generation = 0;

  /// Current input lifecycle.
  GraphVoiceInputState get state => _state;

  /// Whether an STT branch is attached to the active capture hub.
  bool get isRecognitionEnabled => _recognitionBranch?.route != null;

  @override
  Stream<SpeechRecognitionEvent> get transcripts =>
      _transcriptController.stream;

  @override
  Stream<VoiceActivityEvent> get voiceActivity =>
      _voiceActivityController.stream;

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) {
    _ensureOpen();
    cancellationToken?.throwIfCancelled();
    if (_state == GraphVoiceInputState.active) {
      return Future<void>.value();
    }
    final Future<void>? existing = _startFuture;
    if (existing != null) {
      return existing;
    }
    late final Future<void> tracked;
    tracked = _enqueue(() => _start(cancellationToken)).whenComplete(() {
      if (identical(_startFuture, tracked)) {
        _startFuture = null;
      }
    });
    _startFuture = tracked;
    return tracked;
  }

  Future<void> _start(AudioCancellationToken? cancellationToken) async {
    _ensureOpen();
    cancellationToken?.throwIfCancelled();
    if (_state == GraphVoiceInputState.active) {
      return;
    }
    if (_hub != null) {
      await _disposeGraph(abort: true);
    }

    final int generation = ++_generation;
    final AudioCancellationController sessionCancellation =
        AudioCancellationController();
    _sessionCancellation = sessionCancellation;
    _recognitionDesired = true;
    _failureReported = false;
    _state = GraphVoiceInputState.starting;
    _externalCancellationRegistration = cancellationToken?.register((
      AudioCancellation cancellation,
    ) {
      sessionCancellation.cancel(cancellation);
      if (generation == _generation &&
          identical(_sessionCancellation, sessionCancellation)) {
        _requestCancellationAbort(cancellation);
      }
    });

    try {
      cancellationToken?.throwIfCancelled();
      sessionCancellation.token.throwIfCancelled();
      final AudioHub hub = await AudioHub.prepare(
        source,
        cancellationToken: sessionCancellation.token,
      );
      if (generation != _generation || _closeRequested) {
        await hub.abort();
        await hub.close();
        throw const AudioCancelledException(
          AudioCancellation(reason: 'voice_input_start_superseded'),
        );
      }
      _hub = hub;
      _listenToHub(hub, generation);

      final List<VoiceInputRoute> additionalRoutes = await _buildExtraRoutes(
        hub.source.format,
      );
      _validateRouteIds(additionalRoutes);
      sessionCancellation.token.throwIfCancelled();
      await _prepareVoiceActivityBranch(hub, sessionCancellation, generation);
      sessionCancellation.token.throwIfCancelled();
      if (_recognitionDesired) {
        await _prepareRecognitionBranch(hub, sessionCancellation, generation);
      }
      sessionCancellation.token.throwIfCancelled();
      for (final VoiceInputRoute route in additionalRoutes) {
        await hub.attach(
          id: route.id,
          sink: route.sink,
          options: route.options,
          cancellationToken: sessionCancellation.token,
        );
        sessionCancellation.token.throwIfCancelled();
        if (generation != _generation || _closeRequested) {
          throw const AudioCancelledException(
            AudioCancellation(reason: 'voice_input_start_superseded'),
          );
        }
      }
      await hub.start(cancellationToken: sessionCancellation.token);
      sessionCancellation.token.throwIfCancelled();
      if (generation != _generation ||
          _closeRequested ||
          _state == GraphVoiceInputState.stopping) {
        throw const AudioCancelledException(
          AudioCancellation(reason: 'voice_input_start_superseded'),
        );
      }
      _state = GraphVoiceInputState.active;
    } catch (error, stackTrace) {
      final bool cancelled =
          error is AudioCancelledException ||
          sessionCancellation.token.isCancelled;
      try {
        await _disposeGraph(
          abort: true,
          failure: cancelled ? null : _audioFailure(error, 'start_failed'),
        );
      } catch (_) {
        // The initiating startup error remains authoritative.
      }
      if (!_closeRequested) {
        _state = cancelled
            ? GraphVoiceInputState.idle
            : GraphVoiceInputState.failed;
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (identical(_sessionCancellation, sessionCancellation) &&
          _hub == null) {
        _sessionCancellation = null;
      }
    }
  }

  void _listenToHub(AudioHub hub, int generation) {
    _routerEvents = hub.router.events.listen((AudioRouteEvent event) {
      if (generation != _generation || event is! AudioRouteFailed) {
        return;
      }
      if (event.routeId == recognitionRouteId) {
        if (_recognitionBranch?.expectedTerminal ?? true) {
          return;
        }
        _reportFailure(
          event.failure,
          _FailureChannel.recognition,
          at: event.timestamp,
        );
      } else if (event.routeId == voiceActivityRouteId) {
        if (_voiceActivityBranch?.expectedTerminal ?? true) {
          return;
        }
        _reportFailure(
          event.failure,
          _FailureChannel.voiceActivity,
          at: event.timestamp,
        );
      }
    });
    _sourceStatuses = hub.source.statuses.listen(
      (AudioSessionStatus status) {
        if (generation != _generation ||
            _state == GraphVoiceInputState.stopping ||
            _state == GraphVoiceInputState.idle ||
            _state == GraphVoiceInputState.closed) {
          return;
        }
        switch (status.state) {
          case AudioSessionState.failed:
            _reportFailure(
              status.failure ??
                  AudioFailure(
                    code: 'voice_input_source_failed',
                    stage: AudioFailureStage.capture,
                    message: 'The voice capture source failed.',
                    retryable: true,
                  ),
              _FailureChannel.source,
            );
            return;
          case AudioSessionState.aborted:
          case AudioSessionState.finished:
          case AudioSessionState.closed:
            _reportFailure(
              AudioFailure(
                code: 'voice_input_source_ended',
                stage: AudioFailureStage.capture,
                message: 'The voice capture source ended unexpectedly.',
                retryable: true,
              ),
              _FailureChannel.source,
            );
            return;
          case AudioSessionState.prepared:
          case AudioSessionState.starting:
          case AudioSessionState.active:
          case AudioSessionState.paused:
          case AudioSessionState.finishing:
            break;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _reportFailure(
          _audioFailure(error, 'source_status_failed'),
          _FailureChannel.source,
          stackTrace: stackTrace,
        );
      },
    );
  }

  Future<void> _prepareVoiceActivityBranch(
    AudioHub hub,
    AudioCancellationController sessionCancellation,
    int generation,
  ) async {
    final GraphVoiceActivityOptions options = voiceActivityOptions;
    VoiceActivityDetectionSession? session;
    _VoiceActivityBranch? branch;
    var attached = false;
    try {
      session = await voiceActivityDetection.prepareVoiceActivityDetection(
        VoiceActivityDetectionRequest(
          inputFormat: hub.source.format,
          startThreshold: options.startThreshold,
          endThreshold: options.endThreshold,
          minimumSpeech: options.minimumSpeech,
          minimumSilence: options.minimumSilence,
          cancellation: sessionCancellation.token,
          providerOptions: options.providerOptions,
        ),
      );
      sessionCancellation.token.throwIfCancelled();
      if (generation != _generation) {
        throw const AudioCancelledException(
          AudioCancellation(reason: 'voice_input_start_superseded'),
        );
      }
      branch = _VoiceActivityBranch(session);
      _voiceActivityBranch = branch;
      branch.events = session.events.listen(
        (VoiceActivityEvent event) {
          if (identical(_voiceActivityBranch, branch) &&
              !branch!.expectedTerminal &&
              !_voiceActivityController.isClosed) {
            _voiceActivityController.add(event);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_voiceActivityBranch, branch) &&
              !branch!.expectedTerminal) {
            _reportFailure(
              _audioFailure(error, 'vad_events_failed'),
              _FailureChannel.voiceActivity,
              stackTrace: stackTrace,
            );
          }
        },
        onDone: () {
          if (identical(_voiceActivityBranch, branch) &&
              !branch!.expectedTerminal) {
            _reportFailure(
              AudioFailure(
                code: 'voice_input_vad_events_closed',
                stage: AudioFailureStage.provider,
                providerId: voiceActivityDetection.descriptor.id,
                message: 'Voice-activity detection stopped unexpectedly.',
                retryable: true,
              ),
              _FailureChannel.voiceActivity,
            );
          }
        },
      );
      branch.statuses = session.statuses.listen(
        (AudioSessionStatus status) => _onVoiceActivityStatus(branch!, status),
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_voiceActivityBranch, branch) &&
              !branch!.expectedTerminal) {
            _reportFailure(
              _audioFailure(error, 'vad_status_failed'),
              _FailureChannel.voiceActivity,
              stackTrace: stackTrace,
            );
          }
        },
      );
      branch.route = hub.attachPrepared(
        id: voiceActivityRouteId,
        sink: session,
        options: _voiceActivityRouteOptions,
      );
      attached = true;
    } catch (_) {
      branch?.expectedTerminal = true;
      try {
        await branch?.cancelObservers();
      } on Object {
        // Preserve the provider preparation or attachment failure.
      }
      if (!attached && session != null) {
        try {
          await session.abort();
        } on Object {
          // Cleanup continues independently.
        }
        try {
          await session.close();
        } on Object {
          // Preserve the provider preparation or attachment failure.
        }
      }
      if (identical(_voiceActivityBranch, branch)) {
        _voiceActivityBranch = null;
      }
      rethrow;
    }
  }

  Future<void> _prepareRecognitionBranch(
    AudioHub hub,
    AudioCancellationController sessionCancellation,
    int generation, {
    AudioCancellationToken? operationCancellation,
  }) async {
    final AudioCancellationController recognitionCancellation =
        AudioCancellationController();
    _preparingRecognitionCancellation = recognitionCancellation;
    final AudioCancellationRegistration sessionRegistration =
        sessionCancellation.token.register(recognitionCancellation.cancel);
    final AudioCancellationRegistration? operationRegistration =
        operationCancellation?.register(recognitionCancellation.cancel);

    StreamingSpeechToTextSession? session;
    _RecognitionBranch? branch;
    var attached = false;
    try {
      operationCancellation?.throwIfCancelled();
      session = await streamingSpeechToText.prepareStreamingRecognition(
        StreamingRecognitionRequest(
          inputFormat: hub.source.format,
          options: recognitionOptions,
          cancellation: recognitionCancellation.token,
        ),
      );
      recognitionCancellation.token.throwIfCancelled();
      if (generation != _generation ||
          !_recognitionDesired ||
          _state == GraphVoiceInputState.stopping) {
        throw const AudioCancelledException(
          AudioCancellation(reason: 'recognition_prepare_superseded'),
        );
      }
      branch = _RecognitionBranch(
        session,
        recognitionCancellation,
        sessionRegistration,
      );
      _recognitionBranch = branch;
      branch.results = session.results.listen(
        (SpeechRecognitionEvent event) {
          if (!identical(_recognitionBranch, branch) ||
              branch!.expectedTerminal ||
              _transcriptController.isClosed) {
            return;
          }
          _transcriptController.add(event);
          if (event is RecognitionFailed) {
            _reportFailure(
              AudioFailure(
                code: event.failure.code,
                stage: AudioFailureStage.provider,
                providerId: event.failure.providerId,
                message: event.failure.safeMessage,
                retryable: event.failure.retryable,
                safeCause: event.failure.safeCause,
              ),
              _FailureChannel.recognition,
              at: event.at,
              recognitionFailureAlreadyEmitted: true,
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_recognitionBranch, branch) &&
              !branch!.expectedTerminal) {
            _reportFailure(
              _audioFailure(error, 'recognition_events_failed'),
              _FailureChannel.recognition,
              stackTrace: stackTrace,
            );
          }
        },
        onDone: () {
          if (identical(_recognitionBranch, branch) &&
              !branch!.expectedTerminal) {
            _reportFailure(
              AudioFailure(
                code: 'voice_input_recognition_events_closed',
                stage: AudioFailureStage.provider,
                providerId: streamingSpeechToText.descriptor.id,
                message: 'Speech recognition stopped unexpectedly.',
                retryable: true,
              ),
              _FailureChannel.recognition,
            );
          }
        },
      );
      branch.statuses = session.statuses.listen(
        (AudioSessionStatus status) => _onRecognitionStatus(branch!, status),
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_recognitionBranch, branch) &&
              !branch!.expectedTerminal) {
            _reportFailure(
              _audioFailure(error, 'recognition_status_failed'),
              _FailureChannel.recognition,
              stackTrace: stackTrace,
            );
          }
        },
      );
      branch.route = hub.attachPrepared(
        id: recognitionRouteId,
        sink: session,
        options: _recognitionRouteOptions,
      );
      attached = true;
      operationCancellation?.throwIfCancelled();
    } catch (_) {
      branch?.expectedTerminal = true;
      try {
        await branch?.cancelObservers();
      } on Object {
        // Preserve the provider preparation or attachment failure.
      }
      recognitionCancellation.cancel(
        const AudioCancellation(reason: 'recognition_prepare_failed'),
      );
      if (!attached && session != null) {
        try {
          await session.abort();
        } on Object {
          // Cleanup continues independently.
        }
        try {
          await session.close();
        } on Object {
          // Preserve the provider preparation or attachment failure.
        }
      } else if (attached) {
        try {
          await branch?.route?.detach(drain: false);
        } on Object {
          // Preserve the provider preparation or cancellation failure.
        }
      }
      if (identical(_recognitionBranch, branch)) {
        _recognitionBranch = null;
      }
      rethrow;
    } finally {
      operationRegistration?.dispose();
      if (branch == null) {
        sessionRegistration.dispose();
      }
      if (identical(
        _preparingRecognitionCancellation,
        recognitionCancellation,
      )) {
        _preparingRecognitionCancellation = null;
      }
    }
  }

  void _onRecognitionStatus(
    _RecognitionBranch branch,
    AudioSessionStatus status,
  ) {
    if (!identical(_recognitionBranch, branch) || branch.expectedTerminal) {
      return;
    }
    _handleRequiredBranchStatus(
      status,
      _FailureChannel.recognition,
      providerId: streamingSpeechToText.descriptor.id,
    );
  }

  void _onVoiceActivityStatus(
    _VoiceActivityBranch branch,
    AudioSessionStatus status,
  ) {
    if (!identical(_voiceActivityBranch, branch) || branch.expectedTerminal) {
      return;
    }
    _handleRequiredBranchStatus(
      status,
      _FailureChannel.voiceActivity,
      providerId: voiceActivityDetection.descriptor.id,
    );
  }

  void _handleRequiredBranchStatus(
    AudioSessionStatus status,
    _FailureChannel channel, {
    required String providerId,
  }) {
    switch (status.state) {
      case AudioSessionState.failed:
        _reportFailure(
          status.failure ??
              AudioFailure(
                code: 'voice_input_provider_failed',
                stage: AudioFailureStage.provider,
                providerId: providerId,
                message: 'A required voice provider failed.',
                retryable: true,
              ),
          channel,
          at: status.timestamp,
        );
        return;
      case AudioSessionState.finished:
      case AudioSessionState.aborted:
      case AudioSessionState.closed:
        _reportFailure(
          AudioFailure(
            code: 'voice_input_provider_ended',
            stage: AudioFailureStage.provider,
            providerId: providerId,
            message: 'A required voice provider stopped unexpectedly.',
            retryable: true,
          ),
          channel,
          at: status.timestamp,
        );
        return;
      case AudioSessionState.prepared:
      case AudioSessionState.starting:
      case AudioSessionState.active:
      case AudioSessionState.paused:
      case AudioSessionState.finishing:
        break;
    }
  }

  @override
  Future<void> setRecognitionEnabled(
    bool enabled, {
    AudioCancellationToken? cancellationToken,
  }) {
    _ensureOpen();
    cancellationToken?.throwIfCancelled();
    if (_state != GraphVoiceInputState.active) {
      return Future<void>.error(
        StateError('Voice input must be active before recognition is gated.'),
      );
    }

    _recognitionDesired = enabled;
    if (!enabled) {
      final _RecognitionBranch? branch = _recognitionBranch;
      if (branch != null) {
        branch.expectedTerminal = true;
        branch.cancellation.cancel(
          const AudioCancellation(reason: 'recognition_gated'),
        );
      }
      _preparingRecognitionCancellation?.cancel(
        const AudioCancellation(reason: 'recognition_gated'),
      );
    }

    return _enqueue(() async {
      cancellationToken?.throwIfCancelled();
      if (_state != GraphVoiceInputState.active) {
        throw StateError('Voice input is no longer active.');
      }
      if (enabled) {
        if (_recognitionBranch?.route != null) {
          return;
        }
        final AudioHub? hub = _hub;
        final AudioCancellationController? sessionCancellation =
            _sessionCancellation;
        if (hub == null || sessionCancellation == null) {
          throw StateError('Voice input has no active capture graph.');
        }
        await _prepareRecognitionBranch(
          hub,
          sessionCancellation,
          _generation,
          operationCancellation: cancellationToken,
        );
      } else {
        await _disableRecognition();
      }
      cancellationToken?.throwIfCancelled();
    });
  }

  Future<void> _disableRecognition() async {
    final _RecognitionBranch? branch = _recognitionBranch;
    if (branch == null) {
      return;
    }
    branch.expectedTerminal = true;
    branch.cancellation.cancel(
      const AudioCancellation(reason: 'recognition_gated'),
    );
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await branch.cancelObservers();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await branch.route?.detach(drain: false);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (identical(_recognitionBranch, branch)) {
      _recognitionBranch = null;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }

  Future<List<VoiceInputRoute>> _buildExtraRoutes(AudioFormat format) async {
    final VoiceInputRouteBuilder? builder = extraRoutes;
    if (builder == null) {
      return <VoiceInputRoute>[];
    }
    final Iterable<VoiceInputRoute> routes = await builder(format);
    return List<VoiceInputRoute>.of(routes);
  }

  void _validateRouteIds(List<VoiceInputRoute> routes) {
    final Set<String> ids = <String>{recognitionRouteId, voiceActivityRouteId};
    for (final VoiceInputRoute route in routes) {
      if (!ids.add(route.id)) {
        throw ArgumentError.value(
          route.id,
          'extraRoutes',
          'Voice input route IDs must be unique and must not use reserved '
              'IDs "$recognitionRouteId" or "$voiceActivityRouteId".',
        );
      }
    }
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) {
    if (_state == GraphVoiceInputState.closed ||
        _state == GraphVoiceInputState.idle) {
      return Future<void>.value();
    }
    final Future<void>? existing = _stopFuture;
    if (existing != null) {
      return existing;
    }
    cancellationToken?.throwIfCancelled();
    if (_state == GraphVoiceInputState.starting) {
      _sessionCancellation?.cancel(
        const AudioCancellation(reason: 'voice_input_stopped_during_start'),
      );
      _preparingRecognitionCancellation?.cancel(
        const AudioCancellation(reason: 'voice_input_stopped_during_start'),
      );
    }
    _state = GraphVoiceInputState.stopping;
    _markBranchesExpectedTerminal();

    late final Future<void> tracked;
    tracked = _enqueue(() => _stop(cancellationToken)).whenComplete(() {
      if (identical(_stopFuture, tracked)) {
        _stopFuture = null;
      }
    });
    _stopFuture = tracked;
    return tracked;
  }

  Future<void> _stop(AudioCancellationToken? cancellationToken) async {
    cancellationToken?.throwIfCancelled();
    try {
      await _disposeGraph(abort: false, cancellationToken: cancellationToken);
      cancellationToken?.throwIfCancelled();
      if (!_closeRequested) {
        _state = GraphVoiceInputState.idle;
      }
    } catch (error, stackTrace) {
      try {
        await _disposeGraph(
          abort: true,
          failure: _audioFailure(error, 'stop_failed'),
        );
      } catch (_) {
        // Preserve the first shutdown failure.
      }
      if (!_closeRequested) {
        _state = GraphVoiceInputState.failed;
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> close() {
    final Future<void>? existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closeRequested = true;
    _generation += 1;
    _sessionCancellation?.cancel(
      const AudioCancellation(reason: 'voice_input_closed'),
    );
    _preparingRecognitionCancellation?.cancel(
      const AudioCancellation(reason: 'voice_input_closed'),
    );
    _markBranchesExpectedTerminal();
    if (_state != GraphVoiceInputState.idle &&
        _state != GraphVoiceInputState.closed) {
      _state = GraphVoiceInputState.stopping;
    }
    return _closeFuture = _enqueue(_close);
  }

  Future<void> _close() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _disposeGraph(abort: true);
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    _state = GraphVoiceInputState.closed;
    if (!_transcriptController.isClosed) {
      unawaited(_transcriptController.close());
    }
    if (!_voiceActivityController.isClosed) {
      unawaited(_voiceActivityController.close());
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }

  Future<void> _disposeGraph({
    required bool abort,
    AudioFailure? failure,
    AudioCancellationToken? cancellationToken,
  }) async {
    _markBranchesExpectedTerminal();
    final AudioHub? hub = _hub;
    final _RecognitionBranch? recognition = _recognitionBranch;
    final _VoiceActivityBranch? activity = _voiceActivityBranch;
    _hub = null;
    _recognitionBranch = null;
    _voiceActivityBranch = null;
    final AudioCancellationController? sessionCancellation =
        _sessionCancellation;
    _sessionCancellation = null;
    final AudioCancellationRegistration? externalCancellationRegistration =
        _externalCancellationRegistration;
    _externalCancellationRegistration = null;
    _preparingRecognitionCancellation = null;
    externalCancellationRegistration?.dispose();

    final _FirstFailure errors = _FirstFailure();
    await errors.capture(() async {
      await _routerEvents?.cancel();
    });
    _routerEvents = null;
    await errors.capture(() async {
      await _sourceStatuses?.cancel();
    });
    _sourceStatuses = null;
    await errors.capture(() async {
      await recognition?.cancelObservers();
    });
    await errors.capture(() async {
      await activity?.cancelObservers();
    });

    if (abort) {
      sessionCancellation?.cancel(
        const AudioCancellation(reason: 'voice_input_aborted'),
      );
      recognition?.cancellation.cancel(
        const AudioCancellation(reason: 'voice_input_aborted'),
      );
    }

    if (hub != null) {
      if (abort) {
        await errors.capture(() => hub.abort(failure: failure));
      } else {
        await errors.capture(
          () => hub.stop(cancellationToken: cancellationToken),
        );
      }
      await errors.capture(hub.close);
    } else {
      await errors.capture(() async {
        final StreamingSpeechToTextSession? session = recognition?.session;
        if (session != null && !session.status.isTerminal) {
          await session.abort(failure: failure);
        }
        await session?.close();
      });
      await errors.capture(() async {
        final VoiceActivityDetectionSession? session = activity?.session;
        if (session != null && !session.status.isTerminal) {
          await session.abort(failure: failure);
        }
        await session?.close();
      });
    }
    if (!abort) {
      sessionCancellation?.cancel(
        const AudioCancellation(reason: 'voice_input_stopped'),
      );
      recognition?.cancellation.cancel(
        const AudioCancellation(reason: 'voice_input_stopped'),
      );
    }
    errors.throwIfPresent();
  }

  void _markBranchesExpectedTerminal() {
    final _RecognitionBranch? recognition = _recognitionBranch;
    if (recognition != null) {
      recognition.expectedTerminal = true;
    }
    final _VoiceActivityBranch? activity = _voiceActivityBranch;
    if (activity != null) {
      activity.expectedTerminal = true;
    }
  }

  void _reportFailure(
    AudioFailure failure,
    _FailureChannel channel, {
    Duration at = Duration.zero,
    StackTrace? stackTrace,
    bool recognitionFailureAlreadyEmitted = false,
  }) {
    if (_failureReported ||
        _state == GraphVoiceInputState.stopping ||
        _state == GraphVoiceInputState.idle ||
        _state == GraphVoiceInputState.closed) {
      return;
    }
    _failureReported = true;
    _state = GraphVoiceInputState.failed;
    _markBranchesExpectedTerminal();
    _sessionCancellation?.cancel(
      const AudioCancellation(reason: 'voice_input_failed'),
    );
    _preparingRecognitionCancellation?.cancel(
      const AudioCancellation(reason: 'voice_input_failed'),
    );

    switch (channel) {
      case _FailureChannel.recognition:
        if (!recognitionFailureAlreadyEmitted &&
            !_transcriptController.isClosed) {
          _transcriptController.add(
            RecognitionFailed(
              failure: SpeechFailure(
                code: failure.code,
                stage: failure.stage.name,
                providerId: failure.providerId,
                retryable: failure.retryable,
                safeMessage: failure.message,
                safeCause: failure.safeCause,
              ),
              at: at,
            ),
          );
        }
        break;
      case _FailureChannel.voiceActivity:
        if (!_voiceActivityController.isClosed) {
          _voiceActivityController.addError(
            failure,
            stackTrace ?? StackTrace.current,
          );
        }
        break;
      case _FailureChannel.source:
        if (!_transcriptController.isClosed) {
          _transcriptController.addError(
            failure,
            stackTrace ?? StackTrace.current,
          );
        }
        break;
    }

    unawaited(
      _enqueue(() => _disposeGraph(abort: true, failure: failure)).catchError((
        Object _,
        StackTrace _,
      ) {
        // The typed stream failure is authoritative; close() retries cleanup.
      }),
    );
  }

  void _requestCancellationAbort(AudioCancellation cancellation) {
    _sessionCancellation?.cancel(cancellation);
    _preparingRecognitionCancellation?.cancel(cancellation);
    _markBranchesExpectedTerminal();
    if (_state == GraphVoiceInputState.active) {
      _state = GraphVoiceInputState.stopping;
    }
    unawaited(
      _enqueue(() => _disposeGraph(abort: true))
          .then<void>((_) {
            if (!_closeRequested && _state != GraphVoiceInputState.failed) {
              _state = GraphVoiceInputState.idle;
            }
          })
          .catchError((Object _, StackTrace _) {
            if (!_closeRequested) {
              _state = GraphVoiceInputState.failed;
            }
          }),
    );
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final Future<T> next = _operationTail.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _operationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  void _ensureOpen() {
    if (_closeRequested || _state == GraphVoiceInputState.closed) {
      throw StateError('Graph voice input is closed.');
    }
  }

  AudioFailure _audioFailure(Object error, String code) {
    if (error case final AudioFailure failure) {
      return failure;
    }
    return AudioFailure(
      code: 'voice_input_$code',
      stage: AudioFailureStage.provider,
      message: 'The voice input pipeline could not continue.',
      retryable: true,
      safeCause: error.runtimeType.toString(),
    );
  }
}

enum _FailureChannel { recognition, voiceActivity, source }

final class _RecognitionBranch {
  _RecognitionBranch(
    this.session,
    this.cancellation,
    this.sessionCancellationRegistration,
  );

  final StreamingSpeechToTextSession session;
  final AudioCancellationController cancellation;
  final AudioCancellationRegistration sessionCancellationRegistration;
  StreamSubscription<SpeechRecognitionEvent>? results;
  StreamSubscription<AudioSessionStatus>? statuses;
  AudioRoute? route;
  bool expectedTerminal = false;

  Future<void> cancelObservers() async {
    sessionCancellationRegistration.dispose();
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await results?.cancel();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    results = null;
    try {
      await statuses?.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    statuses = null;
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }
}

final class _VoiceActivityBranch {
  _VoiceActivityBranch(this.session);

  final VoiceActivityDetectionSession session;
  StreamSubscription<VoiceActivityEvent>? events;
  StreamSubscription<AudioSessionStatus>? statuses;
  AudioRoute? route;
  bool expectedTerminal = false;

  Future<void> cancelObservers() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await events?.cancel();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    events = null;
    try {
      await statuses?.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    statuses = null;
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }
}

final class _FirstFailure {
  Object? _error;
  StackTrace? _stackTrace;

  Future<void> capture(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      _error ??= error;
      _stackTrace ??= stackTrace;
    }
  }

  void throwIfPresent() {
    final Object? error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
    }
  }
}
