import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'options.dart';
import 'tts_worker.dart';
import 'worker.dart';

/// Internal synthesis coordinator owned by the unified MLX speech provider.
///
/// It intentionally has no provider descriptor of its own, preventing two
/// separately registrable providers from claiming the stable `mlx` ID.
final class MlxTtsCoordinator {
  MlxTtsCoordinator({
    required MlxTtsWorker worker,
    required this._ensureProviderOpen,
    this.modelId = 'pocket-tts',
    this.defaultVoiceId = 'alba',
    Iterable<String> voiceIds = const <String>['alba'],
  }) : _worker = worker,
       voiceIds = Set<String>.unmodifiable(voiceIds) {
    if (worker.outputSampleRate <= 0) {
      throw ArgumentError.value(
        worker.outputSampleRate,
        'worker.outputSampleRate',
        'Must be positive.',
      );
    }
    if (modelId.trim().isEmpty) {
      throw ArgumentError.value(modelId, 'modelId', 'Must not be empty.');
    }
    if (defaultVoiceId.trim().isEmpty) {
      throw ArgumentError.value(
        defaultVoiceId,
        'defaultVoiceId',
        'Must not be empty.',
      );
    }
    if (this.voiceIds.isEmpty || !this.voiceIds.contains(defaultVoiceId)) {
      throw ArgumentError.value(
        voiceIds,
        'voiceIds',
        'Must contain the default voice.',
      );
    }
    if (this.voiceIds.any((voice) => voice.trim().isEmpty)) {
      throw ArgumentError.value(
        voiceIds,
        'voiceIds',
        'Voice IDs must not be empty.',
      );
    }
  }

  final MlxTtsWorker _worker;
  final void Function() _ensureProviderOpen;
  final Set<_MlxTtsSession> _sessions = <_MlxTtsSession>{};
  int _nextSessionId = 0;

  final String modelId;
  final String defaultVoiceId;
  final Set<String> voiceIds;

  AudioSource synthesize(SpeechSynthesisRequest request) {
    _ensureProviderOpen();
    request.cancellation?.throwIfCancelled();
    if (request.text.trim().isEmpty) {
      throw _speechFailure(
        'mlx_tts_empty_text',
        'Text-to-speech input must not be empty.',
      );
    }
    if (request.modelId != null && request.modelId != modelId) {
      throw _speechFailure(
        'mlx_tts_unknown_model',
        'The selected MLX synthesis model is unavailable.',
      );
    }
    final voiceId = request.voiceId ?? defaultVoiceId;
    if (!voiceIds.contains(voiceId)) {
      throw _speechFailure(
        'mlx_tts_unknown_voice',
        'The selected MLX synthesis voice is unavailable.',
      );
    }
    if (!request.rate.isFinite || request.rate != 1) {
      throw _speechFailure(
        'mlx_tts_rate_unsupported',
        'MLX PocketTTS does not support speaking-rate adjustment.',
      );
    }
    if (!request.pitch.isFinite || request.pitch != 0) {
      throw _speechFailure(
        'mlx_tts_pitch_unsupported',
        'MLX PocketTTS does not support pitch adjustment.',
      );
    }
    final options = _optionsFor(request.providerOptions);
    if (!options.temperature.isFinite ||
        options.temperature < 0 ||
        (options.maxTokens != null && options.maxTokens! <= 0)) {
      throw _speechFailure(
        'mlx_tts_invalid_options',
        'The MLX synthesis parameters are invalid.',
      );
    }
    return _MlxTtsSource(this, request, voiceId, options);
  }

  MlxSynthesisOptions _optionsFor(SpeechProviderOptions? options) {
    if (options == null) {
      return const MlxSynthesisOptions();
    }
    if (options is! MlxSynthesisOptions ||
        options.providerId != mlxSpeechProviderId) {
      throw _speechFailure(
        'mlx_tts_invalid_options',
        'Synthesis options do not belong to MLX Audio.',
      );
    }
    return options;
  }

  Future<AudioSourceSession> _prepare(
    SpeechSynthesisRequest request,
    String voiceId,
    MlxSynthesisOptions options,
    AudioCancellationToken? prepareCancellation,
  ) async {
    _ensureProviderOpen();
    request.cancellation?.throwIfCancelled();
    prepareCancellation?.throwIfCancelled();
    _nextSessionId += 1;
    final sourceId = 'mlx-tts-$_nextSessionId';
    late final _MlxTtsSession session;
    session = _MlxTtsSession(
      ensureProviderOpen: _ensureProviderOpen,
      worker: _worker,
      request: request,
      workerRequest: MlxTtsWorkerRequest(
        text: request.text,
        modelId: modelId,
        voiceId: voiceId,
        languageTag: request.languageTag,
        temperature: options.temperature,
        maxTokens: options.maxTokens,
        seed: options.seed,
      ),
      format: AudioFormat(sampleRate: _worker.outputSampleRate, channels: 1),
      sourceId: sourceId,
      onClosed: () => _sessions.remove(session),
    );
    _sessions.add(session);
    return session;
  }

  Future<void> closeSessions() async {
    final firstError = _FirstError();
    final sessions = List<_MlxTtsSession>.of(_sessions);
    try {
      for (final session in sessions) {
        await firstError.capture(session.close);
      }
    } finally {
      _sessions.clear();
    }
    firstError.throwIfPresent();
  }
}

final class _MlxTtsSource implements AudioSource {
  const _MlxTtsSource(
    this._provider,
    this._request,
    this._voiceId,
    this._options,
  );

  final MlxTtsCoordinator _provider;
  final SpeechSynthesisRequest _request;
  final String _voiceId;
  final MlxSynthesisOptions _options;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) => _provider._prepare(_request, _voiceId, _options, cancellationToken);
}

final class _MlxTtsSession implements AudioSourceSession {
  _MlxTtsSession({
    required this._ensureProviderOpen,
    required this._worker,
    required this._request,
    required this._workerRequest,
    required this.format,
    required this.sourceId,
    required this._onClosed,
  }) : trackId = '$sourceId-speech',
       clockId = '$sourceId-clock',
       _status = const AudioSessionStatus(
         state: AudioSessionState.prepared,
         timestamp: Duration.zero,
       );

  final void Function() _ensureProviderOpen;
  final MlxTtsWorker _worker;
  final SpeechSynthesisRequest _request;
  final MlxTtsWorkerRequest _workerRequest;
  final void Function() _onClosed;

  @override
  final AudioFormat format;

  @override
  final String sourceId;

  @override
  final String trackId;

  @override
  final String clockId;

  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>(
    sync: true,
  );
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _frames.stream,
    pauseSupported: false,
  );
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  final Stopwatch _clock = Stopwatch();
  final AudioCancellationController _lifecycleCancellation =
      AudioCancellationController();

  late AudioSessionStatus _status;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  Future<void>? _abortFuture;
  Future<void>? _closeFuture;
  bool _framesClosed = false;
  bool _closing = false;
  bool _stopRequested = false;
  int _generation = 0;
  int _nextSequence = 0;
  int _nextSampleOffset = 0;
  int _nextWorkerFrameIndex = 0;

  @override
  AudioSourceCapabilities get capabilities =>
      const AudioSourceCapabilities(isRealtime: false);

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses =>
      Stream<AudioSessionStatus>.multi((controller) {
        controller.add(_status);
        final subscription = _statuses.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      }, isBroadcast: true);

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) {
    _ensureNotClosed();
    _throwIfCancelled(cancellationToken);
    final existing = _startFuture;
    if (existing != null) {
      return existing;
    }
    if (_status.state != AudioSessionState.prepared) {
      throw StateError('MLX TTS can only start from prepared state.');
    }
    _ensureProviderOpen();
    _clock.start();
    _setState(AudioSessionState.starting);
    _attachCancellation(_request.cancellation);
    _attachCancellation(cancellationToken);
    final generation = _generation;
    return _startFuture = _generate(generation);
  }

  Future<void> _generate(int generation) async {
    try {
      _throwIfStale(generation);
      _setState(AudioSessionState.active);
      final result = await _worker.synthesize(
        _workerRequest,
        cancellation: _lifecycleCancellation.token,
        onAudioChunk: (chunk) => _emitChunk(chunk, generation),
      );
      _throwIfStale(generation);
      if (result.sampleRate != format.sampleRate ||
          result.sampleCount != _nextSampleOffset ||
          result.frameCount != _nextWorkerFrameIndex) {
        throw _audioFailure(
          'mlx_tts_result_format_invalid',
          'MLX synthesis returned inconsistent audio metadata.',
        );
      }
      await _closeFrames();
      _setState(AudioSessionState.finished);
    } on AudioCancelledException catch (error, stackTrace) {
      if (!_isTerminal(_status.state) &&
          _status.state != AudioSessionState.finishing) {
        _setState(AudioSessionState.aborted);
      }
      await _closeFrames();
      Error.throwWithStackTrace(error, stackTrace);
    } catch (error, stackTrace) {
      if (_isStale(generation)) {
        final cancellation = AudioCancelledException(
          _lifecycleCancellation.token.cancellation ??
              const AudioCancellation(reason: 'session_stopped'),
        );
        if (!_isTerminal(_status.state)) {
          _setState(AudioSessionState.aborted);
        }
        await _closeFrames();
        Error.throwWithStackTrace(cancellation, stackTrace);
      }
      final failure = error is AudioFailure
          ? error
          : error is MlxWorkerException
          ? _mlxWorkerFailure(error)
          : _audioFailure(
              'mlx_tts_synthesis_failed',
              'MLX Audio could not synthesize speech.',
              cause: error,
            );
      _publishFailure(failure, stackTrace);
      await _closeFrames();
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  void _emitChunk(MlxTtsWorkerChunk chunk, int generation) {
    _throwIfStale(generation);
    if (chunk.sampleRate != format.sampleRate ||
        chunk.frameIndex != _nextWorkerFrameIndex ||
        chunk.sampleOffset != _nextSampleOffset) {
      throw _audioFailure(
        'mlx_tts_chunk_format_invalid',
        'MLX synthesis emitted an invalid audio timeline.',
      );
    }
    _frames.add(
      AudioFrame.owned(
        format: format,
        samples: chunk.samples,
        sourceId: sourceId,
        trackId: trackId,
        clockId: clockId,
        sequence: _nextSequence,
        sampleOffset: chunk.sampleOffset,
        timestamp: format.durationForFrames(chunk.sampleOffset),
      ),
    );
    _nextWorkerFrameIndex += 1;
    _nextSequence += 1;
    _nextSampleOffset += chunk.samples.length;
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) {
    _throwIfCancelled(cancellationToken);
    throw UnsupportedError(
      'Synchronous MLX inference cannot be paused without buffering.',
    );
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) {
    _throwIfCancelled(cancellationToken);
    throw UnsupportedError(
      'Synchronous MLX inference cannot be resumed because it is not pausable.',
    );
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) {
    _throwIfCancelled(cancellationToken);
    if (_status.state == AudioSessionState.finished ||
        _status.state == AudioSessionState.closed) {
      return Future<void>.value();
    }
    if (_status.state == AudioSessionState.failed ||
        _status.state == AudioSessionState.aborted) {
      return _abortFuture ?? Future<void>.value();
    }
    return _stopFuture ??= _stop(cancellationToken);
  }

  Future<void> _stop(AudioCancellationToken? cancellationToken) async {
    _requestStop();
    _setState(AudioSessionState.finishing);
    await _awaitStartCancellation();
    await _closeFrames();
    _throwIfCancelled(cancellationToken);
    if (_status.state == AudioSessionState.aborted ||
        _status.state == AudioSessionState.failed ||
        _status.state == AudioSessionState.closed) {
      return;
    }
    _setState(AudioSessionState.finished);
  }

  @override
  Future<void> abort({AudioFailure? failure}) {
    if (_isTerminal(_status.state)) {
      return _abortFuture ?? Future<void>.value();
    }
    return _abortFuture ??= _abort(failure);
  }

  Future<void> _abort(AudioFailure? failure) async {
    _requestStop();
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
    await _closeFrames();
    await _awaitStartCancellation();
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closing = true;
    return _closeFuture = _doClose();
  }

  Future<void> _doClose() async {
    final firstError = _FirstError();
    try {
      if (!_isTerminal(_status.state)) {
        await firstError.capture(abort);
      } else {
        _requestStop();
      }
      await firstError.capture(_awaitStartCancellation);
      await firstError.capture(_closeFrames);
      if (_status.state != AudioSessionState.closed) {
        _setState(AudioSessionState.closed);
      }
      if (!_statuses.isClosed) {
        unawaited(_statuses.close());
      }
    } finally {
      _clock.stop();
      _onClosed();
    }
    firstError.throwIfPresent();
  }

  Future<void> _awaitStartCancellation() async {
    try {
      await _startFuture;
    } on AudioCancelledException {
      // Expected when stop/abort/close cancels active generation.
    } on AudioFailure {
      // An operational failure is already published through status/frames.
    }
  }

  void _attachCancellation(AudioCancellationToken? token) {
    if (token == null) {
      return;
    }
    if (token.isCancelled) {
      _lifecycleCancellation.cancel(
        token.cancellation ?? const AudioCancellation(),
      );
      return;
    }
    unawaited(
      token.whenCancelled.then((cancellation) async {
        if (_status.state == AudioSessionState.closed) {
          return;
        }
        _lifecycleCancellation.cancel(cancellation);
        try {
          await abort();
        } on Object {
          // The start future and status stream retain synthesis failures.
        }
      }),
    );
  }

  void _requestStop() {
    if (!_stopRequested) {
      _stopRequested = true;
      _generation += 1;
    }
    _lifecycleCancellation.cancel(
      const AudioCancellation(reason: 'session_stopped'),
    );
  }

  bool _isStale(int generation) =>
      generation != _generation || _stopRequested || _closing;

  void _throwIfStale(int generation) {
    if (_isStale(generation)) {
      throw AudioCancelledException(
        _lifecycleCancellation.token.cancellation ??
            const AudioCancellation(reason: 'session_stopped'),
      );
    }
  }

  void _throwIfCancelled(AudioCancellationToken? operationToken) {
    _request.cancellation?.throwIfCancelled();
    operationToken?.throwIfCancelled();
  }

  void _ensureNotClosed() {
    if (_closing || _status.state == AudioSessionState.closed) {
      throw StateError('MLX TTS session is closed.');
    }
  }

  Future<void> _closeFrames() async {
    if (_framesClosed) {
      return;
    }
    _framesClosed = true;
    unawaited(_frames.close());
  }

  void _publishFailure(AudioFailure failure, StackTrace stackTrace) {
    if (_isTerminal(_status.state)) {
      return;
    }
    _setState(AudioSessionState.failed, failure: failure);
    if (!_framesClosed) {
      _frames.addError(failure, stackTrace);
    }
  }

  void _setState(AudioSessionState state, {AudioFailure? failure}) {
    _status = AudioSessionStatus(
      state: state,
      timestamp: _clock.elapsed,
      failure: failure,
    );
    if (!_statuses.isClosed) {
      _statuses.add(_status);
    }
  }

  static bool _isTerminal(AudioSessionState state) =>
      state == AudioSessionState.finished ||
      state == AudioSessionState.aborted ||
      state == AudioSessionState.failed ||
      state == AudioSessionState.closed;
}

SpeechFailure _speechFailure(String code, String message) => SpeechFailure(
  code: code,
  stage: 'synthesis',
  providerId: mlxSpeechProviderId,
  safeMessage: message,
);

AudioFailure _audioFailure(String code, String message, {Object? cause}) =>
    AudioFailure(
      code: code,
      stage: AudioFailureStage.provider,
      providerId: mlxSpeechProviderId,
      message: message,
      safeCause: cause?.runtimeType.toString(),
    );

AudioFailure _mlxWorkerFailure(MlxWorkerException error) {
  if (error.code == 'worker_queue_full') {
    return AudioFailure(
      code: 'mlx_tts_busy',
      stage: AudioFailureStage.provider,
      providerId: mlxSpeechProviderId,
      message: 'The local MLX synthesis queue is full.',
      retryable: true,
      safeCause: error.safeCause,
    );
  }
  if (error.code == 'synthesis_output_limit') {
    return AudioFailure(
      code: 'mlx_tts_output_limit',
      stage: AudioFailureStage.provider,
      providerId: mlxSpeechProviderId,
      message: 'MLX synthesis exceeded its configured audio limit.',
      safeCause: error.safeCause,
    );
  }
  return AudioFailure(
    code: 'mlx_tts_synthesis_failed',
    stage: AudioFailureStage.provider,
    providerId: mlxSpeechProviderId,
    message: 'MLX Audio could not synthesize speech.',
    safeCause: error.safeCause,
  );
}

final class _FirstError {
  Object? _error;
  StackTrace? _stackTrace;

  Future<void> capture(FutureOr<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      _error ??= error;
      _stackTrace ??= stackTrace;
    }
  }

  void throwIfPresent() {
    final error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
    }
  }
}
