import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'backend.dart';
import 'duplex.dart';
import 'failure.dart';
import 'interfaces.dart';
import 'sentence_segmenter.dart';
import 'snapshot.dart';
import 'synthesis_queue.dart';
import 'transcript_transform.dart';

/// Orchestrates recognition, a streaming backend, serialized TTS, and barge-in.
///
/// The controller owns and closes its input, backend, TTS provider, and output.
///
/// ## Duplex
///
/// [duplex] selects between the default half-duplex flow and the opt-in
/// full-duplex flow, and is the only thing that varies between them. In half
/// duplex the controller gates recognition off for the duration of playback and
/// treats any voice activity during playback as barge-in. In full duplex it
/// never gates recognition at all — the microphone is expected to be
/// echo-cancelled upstream — and voice activity alone no longer interrupts.
///
/// The controller is deliberately ignorant of *how* the microphone gets
/// cleaned: it takes a [VoiceInput] and a resolved [VoiceDuplexConfig], and the
/// echo canceller is composed a layer up. See [VoiceDuplexConfig] for the full
/// barge-in matrix.
final class VoiceConversationController {
  /// Creates a conversation controller.
  ///
  /// Defaults to half duplex with VAD-driven barge-in. Pass a
  /// [VoiceDuplexConfig.fullDuplex] policy — together with an echo-cancelled
  /// [input] — to let the user speak over playback.
  VoiceConversationController({
    required this.input,
    required this.backend,
    required TextToSpeechProvider synthesizer,
    required VoiceSpeechOutput output,
    this.duplex = const VoiceDuplexConfig.halfDuplex(),
    this.transcriptTransform = const IdentityTranscriptTransform(),
    this.failureMapper = const DefaultVoiceFailureMapper(),
    int maximumSentenceCharacters = 240,
    int maximumQueuedSynthesisSentences = 32,
    int maximumQueuedSynthesisCharacters = 8192,
    String? synthesisModelId,
    String? synthesisVoiceId,
    String? synthesisLanguageTag,
    double synthesisRate = 1,
    double synthesisPitch = 0,
  }) : _sentenceSegmenter = IncrementalSentenceSegmenter(
         maximumCharacters: maximumSentenceCharacters,
       ) {
    _snapshot = VoiceConversationSnapshot.initial.copyWith(
      duplexMode: duplex.mode,
    );
    _synthesis = SerializedSynthesisQueue(
      synthesizer: synthesizer,
      output: output,
      modelId: synthesisModelId,
      voiceId: synthesisVoiceId,
      languageTag: synthesisLanguageTag,
      rate: synthesisRate,
      pitch: synthesisPitch,
      maximumQueuedSentences: maximumQueuedSynthesisSentences,
      maximumQueuedCharacters: maximumQueuedSynthesisCharacters,
      beforePlayback: _beforePlayback,
    );
  }

  /// Input owned by this controller.
  final VoiceInput input;

  /// Backend owned by this controller.
  final VoiceBackend backend;

  /// Resolved duplex policy.
  ///
  /// Check [VoiceDuplexConfig.isDegraded] to detect a full-duplex request that
  /// fell back to half duplex because no echo canceller was available.
  final VoiceDuplexConfig duplex;

  /// Transform applied to final transcripts.
  final VoiceTranscriptTransform transcriptTransform;

  /// Maps implementation errors to user-safe failures.
  final VoiceFailureMapper failureMapper;
  final IncrementalSentenceSegmenter _sentenceSegmenter;
  late final SerializedSynthesisQueue _synthesis;

  final StreamController<VoiceConversationSnapshot> _snapshotController =
      StreamController<VoiceConversationSnapshot>.broadcast(sync: true);
  final StreamController<VoiceBackendEvent> _backendEventController =
      StreamController<VoiceBackendEvent>.broadcast(sync: true);

  VoiceConversationSnapshot _snapshot = VoiceConversationSnapshot.initial;
  VoiceConversationContext _context = const EmptyVoiceConversationContext();
  AudioCancellationController? _sessionCancellation;
  AudioCancellationController? _turnCancellation;
  // Cancelled by `_cancelInputSubscriptions`.
  // ignore: cancel_subscriptions
  StreamSubscription<SpeechRecognitionEvent>? _transcriptSubscription;
  // Cancelled by `_cancelInputSubscriptions`.
  // ignore: cancel_subscriptions
  StreamSubscription<VoiceActivityEvent>? _activitySubscription;
  // Cancelled by both `_cancelBackend` and `_runBackend`'s `finally` block.
  // ignore: cancel_subscriptions
  StreamSubscription<VoiceBackendEvent>? _backendSubscription;
  Completer<void>? _backendDone;
  Timer? _sustainedSpeechTimer;
  String? _pendingFinalTranscript;
  int _transcriptRevision = 0;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  Future<void>? _closeFuture;
  int _startRequestId = 0;
  bool _startQueued = false;
  bool _closeRequested = false;

  /// Current immutable state.
  VoiceConversationSnapshot get current => _snapshot;

  /// State updates. Use [current] as the initial value.
  Stream<VoiceConversationSnapshot> get snapshots => _snapshotController.stream;

  /// Non-stale structured backend events.
  Stream<VoiceBackendEvent> get backendEvents => _backendEventController.stream;

  /// Whether capture is active or being prepared.
  bool get isActive =>
      _snapshot.sessionState == VoiceSessionState.preparing ||
      _snapshot.sessionState == VoiceSessionState.active;

  /// Starts input after subscribing to transcript and VAD streams.
  Future<void> start({
    VoiceConversationContext context = const EmptyVoiceConversationContext(),
  }) {
    _ensureNotClosed();
    if (isActive) {
      return _startFuture ?? Future<void>.value();
    }
    final Future<void>? previousStart = _startFuture;
    if (previousStart != null && _startQueued) {
      return previousStart;
    }
    final int requestId = ++_startRequestId;
    final Future<void>? previousStop = _stopFuture;
    if (previousStart != null || previousStop != null) {
      return _trackStart(
        _startAfterPrevious(
          context,
          requestId,
          previousStart: previousStart,
          previousStop: previousStop,
        ),
        queued: true,
      );
    }
    return _trackStart(_startIfCurrent(context, requestId), queued: false);
  }

  /// Stops the session and invalidates all in-flight turn work.
  Future<void> stop() {
    if (_snapshot.sessionState == VoiceSessionState.closed) {
      return Future<void>.value();
    }
    final Future<void>? existing = _stopFuture;
    if (existing != null) {
      return existing;
    }
    _startRequestId += 1;
    _startQueued = false;
    late final Future<void> tracked;
    tracked = _stop().whenComplete(() {
      if (identical(_stopFuture, tracked)) {
        _stopFuture = null;
      }
    });
    _stopFuture = tracked;
    return tracked;
  }

  /// Sends already-committed text through the same transform and backend path.
  Future<void> submitTranscript(String transcript) {
    _ensureNotClosed();
    if (_snapshot.sessionState != VoiceSessionState.active) {
      throw StateError('Voice conversation is not active.');
    }
    return _acceptFinalTranscript(transcript);
  }

  /// Manually interrupts a thinking or speaking turn.
  Future<void> interruptTurn() async {
    if (_snapshot.sessionState != VoiceSessionState.active ||
        (_snapshot.turnState != VoiceTurnState.thinking &&
            _snapshot.turnState != VoiceTurnState.speaking)) {
      return;
    }
    await _interruptForSpeech();
  }

  /// Stops and releases every owned resource exactly once.
  Future<void> close() {
    final Future<void>? existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closeRequested = true;
    _startRequestId += 1;
    _startQueued = false;
    _cancelSustainedSpeechTimer();
    return _closeFuture = _close();
  }

  Future<void> _startIfCurrent(
    VoiceConversationContext context,
    int requestId,
  ) async {
    if (_closeRequested) {
      throw StateError('Voice conversation controller is closed.');
    }
    if (requestId != _startRequestId) {
      return;
    }
    await _start(context);
  }

  Future<void> _startAfterPrevious(
    VoiceConversationContext context,
    int requestId, {
    required Future<void>? previousStart,
    required Future<void>? previousStop,
  }) async {
    try {
      await previousStop;
    } catch (_) {
      // A fresh start can recover from a failed shutdown after the old
      // operation has settled.
    }
    try {
      await previousStart;
    } catch (_) {
      // The original caller observes the superseded startup failure.
    }
    if (_closeRequested) {
      throw StateError('Voice conversation controller is closed.');
    }
    if (requestId != _startRequestId) {
      return;
    }
    await _start(context);
  }

  Future<void> _trackStart(Future<void> operation, {required bool queued}) {
    late final Future<void> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_startFuture, tracked)) {
        _startFuture = null;
        _startQueued = false;
      }
    });
    _startQueued = queued;
    _startFuture = tracked;
    return tracked;
  }

  Future<void> _start(VoiceConversationContext context) async {
    if (_snapshot.sessionState == VoiceSessionState.failed) {
      await _stop();
    }
    _context = context;
    final AudioCancellationController sessionCancellation =
        AudioCancellationController();
    _sessionCancellation = sessionCancellation;
    _emit(
      _snapshot.copyWith(
        sessionState: VoiceSessionState.preparing,
        turnState: VoiceTurnState.idle,
        clearFailure: true,
      ),
    );

    _transcriptSubscription = input.transcripts.listen(
      _onTranscript,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(_failSession(error, stackTrace, stage: 'input'));
      },
    );
    _activitySubscription = input.voiceActivity.listen(
      _onVoiceActivity,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(_failSession(error, stackTrace, stage: 'vad'));
      },
    );

    try {
      await input.start(cancellationToken: sessionCancellation.token);
      sessionCancellation.token.throwIfCancelled();
      if (!identical(_sessionCancellation, sessionCancellation) ||
          _snapshot.sessionState != VoiceSessionState.preparing) {
        // A stop may have completed while a cancellation-insensitive input was
        // still starting. Stop it again now that startup actually returned.
        await input.stop();
        return;
      }
      _emit(
        _snapshot.copyWith(
          sessionState: VoiceSessionState.active,
          turnState: VoiceTurnState.listening,
        ),
      );
      final pendingFinalTranscript = _pendingFinalTranscript;
      _pendingFinalTranscript = null;
      if (pendingFinalTranscript != null) {
        unawaited(_acceptFinalTranscript(pendingFinalTranscript));
      }
    } on AudioCancelledException {
      try {
        await _cancelInputSubscriptions();
      } on Object {
        // Cancellation remains the startup result.
      }
      try {
        await input.stop();
      } on Object {
        // A superseded startup remains stopped even if cleanup also fails.
      }
      if (identical(_sessionCancellation, sessionCancellation)) {
        _sessionCancellation = null;
      }
      if (_snapshot.sessionState == VoiceSessionState.preparing) {
        _emit(
          _snapshot.copyWith(
            sessionState: VoiceSessionState.idle,
            turnState: VoiceTurnState.idle,
          ),
        );
      }
    } catch (error, stackTrace) {
      try {
        await _cancelInputSubscriptions();
      } on Object {
        // Preserve the original startup failure.
      }
      try {
        await input.stop();
      } on Object {
        // Preserve the original startup failure.
      }
      if (!identical(_sessionCancellation, sessionCancellation) ||
          _snapshot.sessionState != VoiceSessionState.preparing) {
        return;
      }
      _sessionCancellation = null;
      final failure = failureMapper.map(error, stackTrace, stage: 'input');
      _emit(
        _snapshot.copyWith(
          sessionState: VoiceSessionState.failed,
          turnState: VoiceTurnState.idle,
          failure: failure,
        ),
      );
      throw failure;
    }
  }

  Future<void> _stop() async {
    if (_snapshot.sessionState == VoiceSessionState.idle) {
      return;
    }
    _emit(
      _snapshot.copyWith(
        sessionState: VoiceSessionState.stopping,
        turnState: VoiceTurnState.idle,
      ),
    );
    _sessionCancellation?.cancel(
      const AudioCancellation(reason: 'session_stopped'),
    );
    _sessionCancellation = null;
    _turnCancellation?.cancel(
      const AudioCancellation(reason: 'session_stopped'),
    );
    _turnCancellation = null;
    _cancelSustainedSpeechTimer();
    _transcriptRevision++;
    final nextGeneration = _snapshot.generationId + 1;
    _emit(_snapshot.copyWith(generationId: nextGeneration));

    Object? firstFailure;
    StackTrace? firstStackTrace;
    final Future<void> backendCancellation = _guarded(_cancelBackend);
    final Future<void> synthesisInterruption = _guarded(
      () => _synthesis.interrupt(nextGeneration),
    );
    try {
      await synthesisInterruption;
    } catch (error, stackTrace) {
      firstFailure = error;
      firstStackTrace = stackTrace;
    }
    try {
      await backendCancellation;
    } catch (error, stackTrace) {
      firstFailure ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _cancelInputSubscriptions();
    } catch (error, stackTrace) {
      firstFailure ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await input.stop();
    } catch (error, stackTrace) {
      firstFailure ??= error;
      firstStackTrace ??= stackTrace;
    }
    _sentenceSegmenter.reset();
    _pendingFinalTranscript = null;
    _context = const EmptyVoiceConversationContext();

    if (firstFailure == null) {
      _emit(
        _snapshot.copyWith(
          sessionState: VoiceSessionState.idle,
          turnState: VoiceTurnState.idle,
          interimTranscript: '',
          clearFailure: true,
        ),
      );
      return;
    }

    final failure = failureMapper.map(
      firstFailure,
      firstStackTrace ?? StackTrace.current,
      stage: 'shutdown',
    );
    _emit(
      _snapshot.copyWith(
        sessionState: VoiceSessionState.failed,
        turnState: VoiceTurnState.idle,
        failure: failure,
      ),
    );
    throw failure;
  }

  Future<void> _close() async {
    Object? firstFailure;
    StackTrace? firstStackTrace;
    final Future<void>? pendingStart = _startFuture;
    try {
      await stop();
    } catch (error, stackTrace) {
      firstFailure = error;
      firstStackTrace = stackTrace;
    }
    try {
      await pendingStart;
    } catch (_) {
      // A queued start is deliberately rejected by close. Its caller observes
      // that result; dependency cleanup must still proceed.
    }
    try {
      await input.close();
    } catch (error, stackTrace) {
      firstFailure ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await backend.close();
    } catch (error, stackTrace) {
      firstFailure ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _synthesis.close();
    } catch (error, stackTrace) {
      firstFailure ??= error;
      firstStackTrace ??= stackTrace;
    }

    _emit(
      _snapshot.copyWith(
        sessionState: VoiceSessionState.closed,
        turnState: VoiceTurnState.idle,
      ),
    );
    if (!_backendEventController.isClosed) {
      unawaited(_backendEventController.close());
    }
    if (!_snapshotController.isClosed) {
      unawaited(_snapshotController.close());
    }
    if (firstFailure != null) {
      Error.throwWithStackTrace(
        firstFailure,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }

  void _onTranscript(SpeechRecognitionEvent event) {
    if (_snapshot.sessionState != VoiceSessionState.active &&
        _snapshot.sessionState != VoiceSessionState.preparing) {
      return;
    }
    switch (event) {
      case RecognitionSpeechStarted():
        if (_snapshot.turnState == VoiceTurnState.interrupted) {
          _emit(_snapshot.copyWith(turnState: VoiceTurnState.listening));
        }
        break;
      case RecognitionPartial(:final transcript):
        _emit(
          _snapshot.copyWith(
            turnState: _snapshot.turnState == VoiceTurnState.interrupted
                ? VoiceTurnState.listening
                : null,
            interimTranscript: transcript.text,
          ),
        );
        break;
      case RecognitionFinal(:final transcript):
        if (_snapshot.sessionState == VoiceSessionState.preparing) {
          _pendingFinalTranscript = transcript.text;
        } else {
          unawaited(_acceptFinalTranscript(transcript.text));
        }
        break;
      case RecognitionSpeechEnded():
        break;
      case RecognitionFailed(:final failure):
        unawaited(
          _failSession(
            VoiceFailure(
              code: failure.code,
              stage: failure.stage,
              message: failure.safeMessage,
              retryable: failure.retryable,
              providerId: failure.providerId,
              safeCause: failure.safeCause,
            ),
            StackTrace.current,
            stage: 'recognition',
          ),
        );
    }
  }

  void _onVoiceActivity(VoiceActivityEvent event) {
    if (duplex.mode == VoiceDuplexMode.halfDuplex) {
      if (event is VoiceActivityStarted &&
          _snapshot.sessionState == VoiceSessionState.active &&
          _snapshot.turnState == VoiceTurnState.speaking) {
        unawaited(_interruptForSpeech());
      }
      return;
    }
    _onFullDuplexVoiceActivity(event);
  }

  /// Voice activity does not interrupt full duplex — that is the point of it.
  ///
  /// The user talks over the assistant and keeps being transcribed, and the
  /// turn ends when their utterance is actually committed. Only an application
  /// that explicitly asked for [VoiceDuplexConfig.interruptAfterSustainedSpeech]
  /// gets the earlier cut-off, and only after the speech has been sustained for
  /// that long past the detector's own hysteresis.
  void _onFullDuplexVoiceActivity(VoiceActivityEvent event) {
    final Duration? threshold = duplex.interruptAfterSustainedSpeech;
    if (threshold == null) {
      return;
    }
    switch (event) {
      case VoiceActivityStarted():
        if (_snapshot.sessionState != VoiceSessionState.active ||
            _snapshot.turnState != VoiceTurnState.speaking) {
          return;
        }
        final int generationId = _snapshot.generationId;
        _cancelSustainedSpeechTimer();
        _sustainedSpeechTimer = Timer(threshold, () {
          _sustainedSpeechTimer = null;
          if (_snapshot.sessionState == VoiceSessionState.active &&
              _snapshot.turnState == VoiceTurnState.speaking &&
              _snapshot.generationId == generationId) {
            unawaited(_interruptForSpeech());
          }
        });
      case VoiceActivityEnded():
        _cancelSustainedSpeechTimer();
      case VoiceActivityProbability():
        break;
    }
  }

  void _cancelSustainedSpeechTimer() {
    _sustainedSpeechTimer?.cancel();
    _sustainedSpeechTimer = null;
  }

  /// Gates recognition, or does nothing at all in full duplex.
  ///
  /// Full duplex never gates: the microphone is echo-cancelled, so there is
  /// nothing to protect the recognizer from, and tearing the session down and
  /// back up is exactly the stale-generation dance the mode exists to remove.
  /// Skipping the call rather than relying on it being idempotent keeps the
  /// invariant checkable — a full-duplex session issues no gating calls at all.
  Future<void> _setRecognitionEnabled(
    bool enabled, {
    AudioCancellationToken? cancellationToken,
  }) {
    if (duplex.mode == VoiceDuplexMode.fullDuplex) {
      return Future<void>.value();
    }
    return input.setRecognitionEnabled(
      enabled,
      cancellationToken: cancellationToken,
    );
  }

  Future<void> _acceptFinalTranscript(String rawTranscript) async {
    final revision = ++_transcriptRevision;
    String transcript;
    try {
      transcript = (await transcriptTransform.transform(rawTranscript)).trim();
    } catch (error, stackTrace) {
      await _handleTurnFailure(
        _snapshot.generationId,
        error,
        stackTrace,
        stage: 'transcript_transform',
      );
      return;
    }
    if (revision != _transcriptRevision ||
        _snapshot.sessionState != VoiceSessionState.active ||
        transcript.isEmpty) {
      return;
    }

    _turnCancellation?.cancel(const AudioCancellation(reason: 'turn_replaced'));
    _cancelSustainedSpeechTimer();
    final generationId = _snapshot.generationId + 1;
    final cancellation = AudioCancellationController();
    _turnCancellation = cancellation;
    _sentenceSegmenter.reset();
    _emit(
      _snapshot.copyWith(
        generationId: generationId,
        turnState: VoiceTurnState.thinking,
        interimTranscript: '',
        finalTranscript: transcript,
        responseText: '',
        clearLastToolCall: true,
        clearFailure: true,
      ),
    );

    try {
      await _cancelBackend();
      if (!_isCurrent(generationId, cancellation.token)) {
        return;
      }
      await _synthesis.beginGeneration(generationId);
      if (!_isCurrent(generationId, cancellation.token)) {
        return;
      }
      await _setRecognitionEnabled(true, cancellationToken: cancellation.token);
      if (!_isCurrent(generationId, cancellation.token)) {
        return;
      }
      unawaited(_runBackend(transcript, generationId, cancellation));
    } on AudioCancelledException {
      // A newer transcript, interruption, or stop owns the next state.
    } catch (error, stackTrace) {
      if (_isCurrent(generationId, cancellation.token)) {
        await _handleTurnFailure(
          generationId,
          error,
          stackTrace,
          stage: 'turn_setup',
        );
      }
    }
  }

  Future<void> _runBackend(
    String transcript,
    int generationId,
    AudioCancellationController cancellation,
  ) async {
    Object? streamFailure;
    StackTrace? streamFailureStackTrace;
    var failed = false;
    var settled = false;
    final done = Completer<void>();
    _backendDone = done;
    StreamSubscription<VoiceBackendEvent>? subscription;

    try {
      final stream = backend.respond(
        VoiceBackendRequest(
          transcript: transcript,
          context: _context,
          generationId: generationId,
          cancellationToken: cancellation.token,
        ),
      );
      // This local subscription is canceled in `finally`. A field reference is
      // retained separately so a replacement generation can cancel it early.
      // ignore: cancel_subscriptions
      subscription = stream.listen(
        (event) {
          if (settled || !_isCurrent(generationId, cancellation.token)) {
            return;
          }
          final failure = _handleBackendEvent(event, generationId);
          if (failure != null) {
            failed = true;
            settled = true;
            streamFailure = failure;
            streamFailureStackTrace = StackTrace.current;
            if (!done.isCompleted) {
              done.complete();
            }
          } else if (event is VoiceBackendCompleted) {
            settled = true;
            if (!done.isCompleted) {
              done.complete();
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (settled) {
            return;
          }
          failed = true;
          settled = true;
          streamFailure = error;
          streamFailureStackTrace = stackTrace;
          if (!done.isCompleted) {
            done.complete();
          }
        },
        onDone: () {
          settled = true;
          if (!done.isCompleted) {
            done.complete();
          }
        },
      );
      _backendSubscription = subscription;
      await done.future;
      await subscription.cancel();
      if (identical(_backendSubscription, subscription)) {
        _backendSubscription = null;
      }
      subscription = null;
      if (failed) {
        final failure =
            streamFailure ??
            const VoiceFailure(
              code: 'backend_failed',
              stage: 'backend',
              message: 'The response could not be completed.',
            );
        Error.throwWithStackTrace(
          failure,
          streamFailureStackTrace ?? StackTrace.current,
        );
      }
      if (!_isCurrent(generationId, cancellation.token)) {
        return;
      }
      _enqueueSentences(_sentenceSegmenter.flush(), generationId);
      await _synthesis.drain(generationId);
      if (!_isCurrent(generationId, cancellation.token)) {
        return;
      }
      await _setRecognitionEnabled(true, cancellationToken: cancellation.token);
      if (_isCurrent(generationId, cancellation.token)) {
        _emit(_snapshot.copyWith(turnState: VoiceTurnState.listening));
      }
    } catch (error, stackTrace) {
      if (_isCurrent(generationId, cancellation.token)) {
        await _handleTurnFailure(
          generationId,
          error,
          stackTrace,
          stage: 'backend',
        );
      }
    } finally {
      try {
        await subscription?.cancel();
      } on Object {
        // Cancellation errors were already mapped by the active turn path.
      }
      if (identical(_backendSubscription, subscription)) {
        _backendSubscription = null;
      }
      if (identical(_backendDone, done)) {
        _backendDone = null;
      }
    }
  }

  VoiceFailure? _handleBackendEvent(VoiceBackendEvent event, int generationId) {
    if (generationId != _snapshot.generationId) {
      return null;
    }
    _backendEventController.add(event);
    switch (event) {
      case VoiceBackendProgress():
        return null;
      case VoiceNarrativeStarted():
        _sentenceSegmenter.reset();
        _emit(_snapshot.copyWith(responseText: ''));
        return null;
      case VoiceNarrativeDelta(:final text):
        _emit(
          _snapshot.copyWith(responseText: '${_snapshot.responseText}$text'),
        );
        _enqueueSentences(_sentenceSegmenter.add(text), generationId);
        return null;
      case VoiceNarrativeEnded():
        _enqueueSentences(_sentenceSegmenter.flush(), generationId);
        return null;
      case VoiceBackendTool(:final call):
        _emit(_snapshot.copyWith(lastToolCall: call));
        return null;
      case VoiceBackendCompleted():
        return null;
      case VoiceBackendFailed(:final failure):
        return failure;
    }
  }

  void _enqueueSentences(List<String> sentences, int generationId) {
    for (final sentence in sentences) {
      _synthesis.enqueue(generationId: generationId, text: sentence);
    }
  }

  Future<void> _beforePlayback(
    int generationId,
    AudioCancellationToken cancellationToken,
  ) async {
    if (!_isCurrent(generationId, cancellationToken)) {
      cancellationToken.throwIfCancelled();
      return;
    }
    await _setRecognitionEnabled(false, cancellationToken: cancellationToken);
    if (_isCurrent(generationId, cancellationToken)) {
      _emit(_snapshot.copyWith(turnState: VoiceTurnState.speaking));
    }
  }

  Future<void> _interruptForSpeech() async {
    if (_snapshot.sessionState != VoiceSessionState.active) {
      return;
    }
    final nextGeneration = _snapshot.generationId + 1;
    _transcriptRevision++;
    _turnCancellation?.cancel(const AudioCancellation(reason: 'barge_in'));
    _turnCancellation = null;
    _cancelSustainedSpeechTimer();
    _emit(
      _snapshot.copyWith(
        generationId: nextGeneration,
        turnState: VoiceTurnState.interrupted,
        interimTranscript: '',
      ),
    );
    final Future<void> backendCancellation = _guarded(_cancelBackend);
    final Future<void> synthesisInterruption = _guarded(
      () => _synthesis.interrupt(nextGeneration),
    );
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    try {
      await synthesisInterruption;
    } catch (error, stackTrace) {
      cleanupError = error;
      cleanupStackTrace = stackTrace;
    }
    if (_snapshot.generationId != nextGeneration ||
        _snapshot.sessionState != VoiceSessionState.active) {
      try {
        await backendCancellation;
      } on Object {
        // A newer generation owns the user-visible state.
      }
      return;
    }
    try {
      await _setRecognitionEnabled(true);
    } catch (error, stackTrace) {
      cleanupError ??= error;
      cleanupStackTrace ??= stackTrace;
    }
    try {
      await backendCancellation;
    } catch (error, stackTrace) {
      cleanupError ??= error;
      cleanupStackTrace ??= stackTrace;
    }
    if (cleanupError != null &&
        _snapshot.sessionState == VoiceSessionState.active &&
        _snapshot.generationId == nextGeneration) {
      _emit(
        _snapshot.copyWith(
          turnState: VoiceTurnState.listening,
          failure: failureMapper.map(
            cleanupError,
            cleanupStackTrace ?? StackTrace.current,
            stage: 'interruption',
          ),
        ),
      );
    }
  }

  Future<void> _handleTurnFailure(
    int generationId,
    Object error,
    StackTrace stackTrace, {
    required String stage,
  }) async {
    if (generationId != _snapshot.generationId ||
        _snapshot.sessionState != VoiceSessionState.active) {
      return;
    }
    final failure = failureMapper.map(error, stackTrace, stage: stage);
    final nextGeneration = generationId + 1;
    _turnCancellation?.cancel(const AudioCancellation(reason: 'turn_failed'));
    _turnCancellation = null;
    _cancelSustainedSpeechTimer();
    _emit(
      _snapshot.copyWith(
        generationId: nextGeneration,
        turnState: VoiceTurnState.listening,
        failure: failure,
      ),
    );
    final Future<void> backendCancellation = _guarded(_cancelBackend);
    final Future<void> synthesisInterruption = _guarded(
      () => _synthesis.interrupt(nextGeneration),
    );
    try {
      await synthesisInterruption;
    } on Object {
      // Preserve the original mapped turn failure.
    }
    try {
      await backendCancellation;
    } on Object {
      // Preserve the original mapped turn failure.
    }
    if (_snapshot.sessionState == VoiceSessionState.active &&
        _snapshot.generationId == nextGeneration) {
      try {
        await _setRecognitionEnabled(true);
      } on Object {
        // The original turn failure remains user-visible.
      }
    }
  }

  Future<void> _failSession(
    Object error,
    StackTrace stackTrace, {
    required String stage,
  }) async {
    if (_snapshot.sessionState == VoiceSessionState.closed ||
        _snapshot.sessionState == VoiceSessionState.failed ||
        _snapshot.sessionState == VoiceSessionState.stopping) {
      return;
    }
    final failure = failureMapper.map(error, stackTrace, stage: stage);
    _sessionCancellation?.cancel(
      const AudioCancellation(reason: 'session_failed'),
    );
    _turnCancellation?.cancel(
      const AudioCancellation(reason: 'session_failed'),
    );
    _cancelSustainedSpeechTimer();
    final nextGeneration = _snapshot.generationId + 1;
    _emit(
      _snapshot.copyWith(
        sessionState: VoiceSessionState.failed,
        turnState: VoiceTurnState.idle,
        generationId: nextGeneration,
        failure: failure,
      ),
    );
    final Future<void> backendCancellation = _guarded(_cancelBackend);
    final Future<void> synthesisInterruption = _guarded(
      () => _synthesis.interrupt(nextGeneration),
    );
    try {
      await synthesisInterruption;
    } on Object {
      // Preserve the original session failure.
    }
    try {
      await backendCancellation;
    } on Object {
      // Preserve the original session failure.
    }
    try {
      await _cancelInputSubscriptions();
    } on Object {
      // Preserve the original session failure.
    }
    try {
      await input.stop();
    } on Object {
      // The original failure remains the user-visible cause.
    }
  }

  Future<void> _cancelBackend() async {
    final subscription = _backendSubscription;
    final done = _backendDone;
    _backendSubscription = null;
    _backendDone = null;
    Object? failure;
    StackTrace? failureStackTrace;
    try {
      await subscription?.cancel();
    } catch (error, stackTrace) {
      failure = error;
      failureStackTrace = stackTrace;
    } finally {
      if (done != null && !done.isCompleted) {
        done.complete();
      }
    }
    if (failure != null) {
      Error.throwWithStackTrace(
        failure,
        failureStackTrace ?? StackTrace.current,
      );
    }
  }

  Future<void> _cancelInputSubscriptions() async {
    final transcriptSubscription = _transcriptSubscription;
    final activitySubscription = _activitySubscription;
    _transcriptSubscription = null;
    _activitySubscription = null;
    Object? failure;
    StackTrace? failureStackTrace;
    try {
      await transcriptSubscription?.cancel();
    } catch (error, stackTrace) {
      failure = error;
      failureStackTrace = stackTrace;
    }
    try {
      await activitySubscription?.cancel();
    } catch (error, stackTrace) {
      failure ??= error;
      failureStackTrace ??= stackTrace;
    }
    if (failure != null) {
      Error.throwWithStackTrace(
        failure,
        failureStackTrace ?? StackTrace.current,
      );
    }
  }

  bool _isCurrent(int generationId, AudioCancellationToken cancellationToken) =>
      _snapshot.sessionState == VoiceSessionState.active &&
      generationId == _snapshot.generationId &&
      !cancellationToken.isCancelled;

  void _emit(VoiceConversationSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  void _ensureNotClosed() {
    if (_closeRequested ||
        _closeFuture != null ||
        _snapshot.sessionState == VoiceSessionState.closed) {
      throw StateError('Voice conversation controller is closed.');
    }
  }
}

Future<void> _guarded(Future<void> Function() operation) {
  try {
    return operation();
  } catch (error, stackTrace) {
    return Future<void>.error(error, stackTrace);
  }
}
