import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'auth.dart';
import 'http_transport.dart';
import 'options.dart';
import 'transport.dart';

/// OpenAI text-to-speech whose output follows the normal [AudioSource] lifecycle.
final class OpenAiTextToSpeechProvider extends IdempotentSpeechProvider
    implements TextToSpeechProvider {
  factory OpenAiTextToSpeechProvider({
    required OpenAiTokenSource tokenSource,
    OpenAiTtsTransport? transport,
    OpenAiTtsProviderConfig? config,
  }) => OpenAiTextToSpeechProvider._(
    tokenSource,
    transport ?? HttpOpenAiTtsTransport(),
    config ?? OpenAiTtsProviderConfig(),
  );

  OpenAiTextToSpeechProvider._(this._tokenSource, this._transport, this.config)
    : descriptor = SpeechProviderDescriptor(
        id: providerId,
        displayName: 'OpenAI',
        capabilities: <SpeechCapability>{SpeechCapability.textToSpeech},
        models: <SpeechModelDescriptor>[
          SpeechModelDescriptor(
            id: 'gpt-4o-mini-tts',
            providerId: providerId,
            displayName: 'GPT-4o mini TTS',
            capabilities: <SpeechCapability>{SpeechCapability.textToSpeech},
          ),
          SpeechModelDescriptor(
            id: 'tts-1',
            providerId: providerId,
            displayName: 'TTS-1',
            capabilities: <SpeechCapability>{SpeechCapability.textToSpeech},
          ),
          SpeechModelDescriptor(
            id: 'tts-1-hd',
            providerId: providerId,
            displayName: 'TTS-1 HD',
            capabilities: <SpeechCapability>{SpeechCapability.textToSpeech},
          ),
        ],
        voices: <SpeechVoiceDescriptor>[
          for (final String voice in <String>[
            'alloy',
            'ash',
            'ballad',
            'coral',
            'echo',
            'fable',
            'nova',
            'onyx',
            'sage',
            'shimmer',
            'verse',
            'marin',
            'cedar',
          ])
            SpeechVoiceDescriptor(
              id: voice,
              providerId: providerId,
              displayName: _titleCase(voice),
            ),
        ],
      );

  /// Stable provider identifier.
  static const String providerId = 'openai';

  final OpenAiTokenSource _tokenSource;
  final OpenAiTtsTransport _transport;

  /// Endpoint, framing, and response limits.
  final OpenAiTtsProviderConfig config;

  final Set<_OpenAiTtsSession> _sessions = <_OpenAiTtsSession>{};
  int _nextSessionId = 0;

  @override
  final SpeechProviderDescriptor descriptor;

  @override
  AudioSource synthesize(SpeechSynthesisRequest request) {
    ensureOpen();
    if (request.text.trim().isEmpty) {
      throw SpeechFailure(
        code: 'openai_text_empty',
        stage: 'synthesis',
        providerId: providerId,
        safeMessage: 'Text to synthesize must not be empty.',
      );
    }
    if (request.text.length > 4096) {
      throw SpeechFailure(
        code: 'openai_text_too_long',
        stage: 'synthesis',
        providerId: providerId,
        safeMessage: 'OpenAI synthesis text must not exceed 4096 characters.',
      );
    }
    if (!request.rate.isFinite || request.rate < 0.25 || request.rate > 4) {
      throw SpeechFailure(
        code: 'openai_rate_unsupported',
        stage: 'synthesis',
        providerId: providerId,
        safeMessage: 'OpenAI speaking rate must be between 0.25 and 4.',
      );
    }
    if (request.pitch != 0) {
      throw SpeechFailure(
        code: 'openai_pitch_unsupported',
        stage: 'synthesis',
        providerId: providerId,
        safeMessage: 'OpenAI does not support explicit pitch adjustment.',
      );
    }
    final OpenAiTtsOptions options = _optionsFor(request);
    final String modelId = request.modelId ?? config.defaultModelId;
    if (options.instructions != null &&
        (modelId == 'tts-1' || modelId == 'tts-1-hd')) {
      throw SpeechFailure(
        code: 'openai_instructions_unsupported',
        stage: 'synthesis',
        providerId: providerId,
        safeMessage: 'The selected OpenAI model does not support instructions.',
      );
    }
    return _OpenAiTtsSource(this, request, options);
  }

  OpenAiTtsOptions _optionsFor(SpeechSynthesisRequest request) {
    final SpeechProviderOptions? providerOptions = request.providerOptions;
    if (providerOptions == null) {
      return const OpenAiTtsOptions();
    }
    if (providerOptions is! OpenAiTtsOptions) {
      throw SpeechFailure(
        code: 'openai_options_invalid',
        stage: 'synthesis',
        providerId: providerId,
        safeMessage: 'Synthesis options do not belong to OpenAI.',
      );
    }
    return providerOptions;
  }

  Future<AudioSourceSession> _prepare(
    SpeechSynthesisRequest request,
    OpenAiTtsOptions options,
    AudioCancellationToken? prepareCancellation,
  ) async {
    ensureOpen();
    request.cancellation?.throwIfCancelled();
    prepareCancellation?.throwIfCancelled();
    _nextSessionId += 1;
    final String sourceId = 'openai-tts-$_nextSessionId';
    late final _OpenAiTtsSession session;
    session = _OpenAiTtsSession(
      this,
      request,
      options,
      AudioFormat(
        sampleRate: config.outputSampleRate,
        channels: config.outputChannels,
      ),
      sourceId,
      () => _sessions.remove(session),
    );
    _sessions.add(session);
    return session;
  }

  Future<OpenAiAccessToken> _token(
    AudioCancellationToken? cancellationToken,
  ) async {
    final OpenAiAccessToken token;
    try {
      token = await _tokenSource.getToken(cancellationToken: cancellationToken);
      cancellationToken?.throwIfCancelled();
    } on AudioCancelledException {
      rethrow;
    } catch (error) {
      throw AudioFailure(
        code: 'openai_token_failed',
        stage: AudioFailureStage.provider,
        providerId: providerId,
        message: 'An OpenAI access token could not be obtained.',
        retryable: true,
        safeCause: error.runtimeType.toString(),
      );
    }
    if (token.value.trim().isEmpty || token.isExpired()) {
      throw AudioFailure(
        code: 'openai_token_invalid',
        stage: AudioFailureStage.provider,
        providerId: providerId,
        message: 'The OpenAI access token is unavailable or expired.',
        retryable: true,
      );
    }
    return token;
  }

  Future<OpenAiTtsTransportOperation> _startTransport(
    SpeechSynthesisRequest request,
    OpenAiTtsOptions options,
    OpenAiAccessToken token,
    AudioCancellationToken cancellationToken,
  ) => _transport.start(
    OpenAiTtsTransportRequest(
      endpoint: config.endpoint,
      authorization: 'Bearer ${token.value}',
      modelId: request.modelId ?? config.defaultModelId,
      voiceId: request.voiceId ?? config.defaultVoiceId,
      text: request.text,
      speed: request.rate,
      responseFormat: options.responseFormat,
      instructions: options.instructions,
      maximumResponseBytes: config.maximumResponseBytes,
    ),
    cancellationToken: cancellationToken,
  );

  @override
  Future<void> onClose() async {
    final List<_OpenAiTtsSession> sessions = List<_OpenAiTtsSession>.of(
      _sessions,
    );
    final _FirstError errors = _FirstError();
    try {
      for (final _OpenAiTtsSession session in sessions) {
        await errors.capture(session.close);
      }
    } finally {
      _sessions.clear();
    }
    await errors.capture(_transport.close);
    errors.throwIfPresent();
  }
}

final class _OpenAiTtsSource implements AudioSource {
  const _OpenAiTtsSource(this._provider, this._request, this._options);

  final OpenAiTextToSpeechProvider _provider;
  final SpeechSynthesisRequest _request;
  final OpenAiTtsOptions _options;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) => _provider._prepare(_request, _options, cancellationToken);
}

final class _OpenAiTtsSession implements AudioSourceSession {
  _OpenAiTtsSession(
    this._provider,
    this._request,
    this._options,
    this.format,
    this.sourceId,
    this._onClosed,
  ) : trackId = '$sourceId-speech',
      clockId = '$sourceId-clock',
      _status = const AudioSessionStatus(
        state: AudioSessionState.prepared,
        timestamp: Duration.zero,
      );

  final OpenAiTextToSpeechProvider _provider;
  final SpeechSynthesisRequest _request;
  final OpenAiTtsOptions _options;
  final void Function() _onClosed;

  @override
  final AudioFormat format;

  @override
  final String sourceId;

  @override
  final String trackId;

  @override
  final String clockId;

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

  late AudioSessionStatus _status;
  final AudioCancellationController _lifecycleCancellation =
      AudioCancellationController();
  OpenAiTtsTransportOperation? _operation;
  Future<void>? _startFuture;
  Future<void>? _pump;
  Future<void>? _terminationFuture;
  Future<void>? _closeFuture;
  Completer<void>? _resumeGate;
  bool _explicitlyPaused = false;
  bool _consumerPaused = false;
  bool _stopRequested = false;
  bool _framesClosed = false;
  bool _closing = false;
  bool _requestCancellationAttached = false;
  int _generation = 0;

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.pausable;

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
    _ensureOpen();
    _throwIfCancelled(cancellationToken);
    if (_status.state == AudioSessionState.active ||
        _status.state == AudioSessionState.finished) {
      return Future<void>.value();
    }
    final Future<void>? existing = _startFuture;
    if (existing != null) {
      return existing;
    }
    if (_status.state != AudioSessionState.prepared) {
      throw StateError('OpenAI TTS can only start from prepared state.');
    }
    _clock.start();
    _setState(AudioSessionState.starting);
    _attachCancellation(_request.cancellation, requestCancellation: true);
    _attachCancellation(cancellationToken);
    final int generation = _generation;
    return _startFuture = _doStart(cancellationToken, generation);
  }

  Future<void> _doStart(
    AudioCancellationToken? operationCancellation,
    int generation,
  ) async {
    try {
      final OpenAiAccessToken token = await _provider._token(
        _lifecycleCancellation.token,
      );
      _throwIfCancelled(operationCancellation);
      _throwIfStale(generation);
      final OpenAiTtsTransportOperation operation = await _provider
          ._startTransport(
            _request,
            _options,
            token,
            _lifecycleCancellation.token,
          );
      _operation = operation;
      _throwIfCancelled(operationCancellation);
      _throwIfStale(generation);
      _setState(AudioSessionState.active);
      _pump = _receiveAndEmit(operation);
    } on AudioCancelledException catch (error, stackTrace) {
      await _abortDuringStart();
      Error.throwWithStackTrace(error, stackTrace);
    } catch (error, stackTrace) {
      if (_isStale(generation)) {
        final AudioCancelledException cancellation = AudioCancelledException(
          _lifecycleCancellation.token.cancellation ??
              const AudioCancellation(reason: 'session_stopped'),
        );
        await _abortDuringStart();
        Error.throwWithStackTrace(cancellation, stackTrace);
      }
      final AudioFailure failure = error is AudioFailure
          ? error
          : _failure(
              code: 'openai_synthesis_start_failed',
              message: 'OpenAI synthesis could not be started.',
              cause: error,
            );
      await _failDuringStart(failure, stackTrace);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  Future<void> _receiveAndEmit(OpenAiTtsTransportOperation operation) async {
    Object? synthesisError;
    StackTrace? synthesisStackTrace;
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    try {
      await _consumeResponse(operation);
    } catch (error, stackTrace) {
      synthesisError = error;
      synthesisStackTrace = stackTrace;
    }
    try {
      await operation.close();
    } catch (error, stackTrace) {
      cleanupError = error;
      cleanupStackTrace = stackTrace;
    }

    final Object? selectedError = synthesisError ?? cleanupError;
    final StackTrace? selectedStackTrace =
        synthesisStackTrace ?? cleanupStackTrace;
    if (selectedError is AudioCancelledException || _stopRequested) {
      if (!_isTerminal(_status.state) &&
          _status.state != AudioSessionState.finishing) {
        _setState(AudioSessionState.aborted);
      }
    } else if (selectedError != null) {
      final AudioFailure failure = selectedError is AudioFailure
          ? selectedError
          : _failure(
              code: synthesisError == null
                  ? 'openai_transport_cleanup_failed'
                  : 'openai_synthesis_failed',
              message: synthesisError == null
                  ? 'OpenAI synthesis resources could not be released.'
                  : 'OpenAI could not synthesize speech.',
              cause: selectedError,
            );
      _publishFailure(failure, selectedStackTrace ?? StackTrace.current);
    } else if (!_stopRequested &&
        (_status.state == AudioSessionState.active ||
            _status.state == AudioSessionState.paused)) {
      _setState(AudioSessionState.finished);
    }

    try {
      await _closeFrames();
    } catch (error, stackTrace) {
      if (!_stopRequested && !_isTerminal(_status.state)) {
        _publishFailure(
          _failure(
            code: 'openai_frame_stream_close_failed',
            message: 'OpenAI audio delivery could not be finalized.',
            cause: error,
          ),
          stackTrace,
        );
      }
    }
  }

  Future<void> _consumeResponse(OpenAiTtsTransportOperation operation) async {
    final OpenAiTtsTransportResponse response = await operation.response;
    _request.cancellation?.throwIfCancelled();
    _lifecycleCancellation.token.throwIfCancelled();
    if (_stopRequested) {
      return;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _failureForResponse(response);
    }
    final int maximumBytes = _provider.config.maximumResponseBytes;
    final int? contentLength = response.contentLength;
    if (contentLength != null && contentLength > maximumBytes) {
      throw _failure(
        code: 'openai_response_too_large',
        message: 'OpenAI returned more audio than this session permits.',
        retryable: false,
      );
    }

    final _StreamingFrameEmitter emitter = _StreamingFrameEmitter(this);
    final _StreamingAudioDecoder decoder = switch (_options.responseFormat) {
      OpenAiTtsResponseFormat.wav => _StreamingWavDecoder(
        expectedFormat: format,
        emitter: emitter,
        maximumHeaderBytes: maximumBytes < _maximumWavHeaderBytes
            ? maximumBytes
            : _maximumWavHeaderBytes,
      ),
      OpenAiTtsResponseFormat.pcm => _StreamingPcm16Decoder(emitter),
    };
    var receivedBytes = 0;
    await for (final Uint8List chunk in response.body) {
      _request.cancellation?.throwIfCancelled();
      _lifecycleCancellation.token.throwIfCancelled();
      if (_stopRequested) {
        return;
      }
      if (chunk.length > maximumBytes - receivedBytes) {
        throw _failure(
          code: 'openai_response_too_large',
          message: 'OpenAI returned more audio than this session permits.',
          retryable: false,
        );
      }
      receivedBytes += chunk.length;
      if (chunk.isNotEmpty) {
        await decoder.add(chunk);
      }
    }
    await decoder.finish();
  }

  Future<bool> _emitFrame(
    Float32List samples,
    int sequence,
    int sampleOffset,
  ) async {
    if (_stopRequested || _isTerminal(_status.state) || _framesClosed) {
      return false;
    }
    final Completer<void>? gate = _resumeGate;
    if (gate != null) {
      await gate.future;
    }
    if (_stopRequested || _isTerminal(_status.state) || _framesClosed) {
      return false;
    }
    _frames.add(
      AudioFrame.owned(
        format: format,
        samples: samples,
        sourceId: sourceId,
        trackId: trackId,
        clockId: clockId,
        sequence: sequence,
        sampleOffset: sampleOffset,
        timestamp: format.durationForFrames(sampleOffset),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    return true;
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    _throwIfCancelled(cancellationToken);
    if (_explicitlyPaused) {
      return;
    }
    if (_status.state != AudioSessionState.active &&
        _status.state != AudioSessionState.paused) {
      throw StateError('Only active OpenAI TTS can be paused.');
    }
    _explicitlyPaused = true;
    _updatePauseState();
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    _throwIfCancelled(cancellationToken);
    if (!_explicitlyPaused) {
      return;
    }
    _explicitlyPaused = false;
    _updatePauseState();
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    _throwIfCancelled(cancellationToken);
    if (_isTerminal(_status.state)) {
      await _terminationFuture;
      return;
    }
    _requestStop();
    if (!_isTerminal(_status.state)) {
      _setState(AudioSessionState.finishing);
    }
    await (_terminationFuture ??= _terminate());
    _throwIfCancelled(cancellationToken);
    if (_status.state == AudioSessionState.finishing) {
      _setState(AudioSessionState.finished);
    }
  }

  Future<void> _terminate() async {
    final _FirstError errors = _FirstError();
    final OpenAiTtsTransportOperation? operationBeforeStart = _operation;
    await errors.capture(() async => operationBeforeStart?.abort());
    await _captureStart(errors);
    await errors.capture(() async => _operation?.close());
    await errors.capture(() async => _pump);
    await errors.capture(_closeFrames);
    errors.throwIfPresent();
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    if (_isTerminal(_status.state)) {
      await _terminationFuture;
      return;
    }
    _requestStop();
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
    await (_terminationFuture ??= _terminate());
  }

  Future<void> _abortDuringStart() async {
    if (!_stopRequested) {
      _requestStop();
    }
    if (!_isTerminal(_status.state) &&
        _status.state != AudioSessionState.finishing) {
      _setState(AudioSessionState.aborted);
    }
    final _FirstError errors = _FirstError();
    await errors.capture(() async => _operation?.abort());
    await errors.capture(() async => _operation?.close());
    await errors.capture(_closeFrames);
    // Cancellation remains the primary start result.
  }

  Future<void> _failDuringStart(
    AudioFailure failure,
    StackTrace stackTrace,
  ) async {
    if (_stopRequested) {
      await _abortDuringStart();
      return;
    }
    _requestStop();
    _publishFailure(failure, stackTrace);
    final _FirstError errors = _FirstError();
    await errors.capture(() async => _operation?.abort());
    await errors.capture(() async => _operation?.close());
    await errors.capture(_closeFrames);
    // Preserve the stable synthesis failure over cleanup failures.
  }

  @override
  Future<void> close() {
    final Future<void>? existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closing = true;
    return _closeFuture = _doClose();
  }

  Future<void> _doClose() async {
    final _FirstError errors = _FirstError();
    if (!_isTerminal(_status.state)) {
      await errors.capture(abort);
    } else {
      _requestStop();
    }
    await errors.capture(() async => _terminationFuture);
    await _captureStart(errors);
    await errors.capture(() async => _pump);
    await errors.capture(() async => _operation?.close());
    await errors.capture(_closeFrames);
    if (_status.state != AudioSessionState.closed) {
      _setState(AudioSessionState.closed);
    }
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
    try {
      _clock.stop();
    } finally {
      _onClosed();
    }
    errors.throwIfPresent();
  }

  Future<void> _closeFrames() {
    if (_framesClosed) {
      return Future<void>.value();
    }
    _framesClosed = true;
    unawaited(_frames.close());
    return Future<void>.value();
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
        _setState(AudioSessionState.paused);
      }
      return;
    }
    final Completer<void>? gate = _resumeGate;
    _resumeGate = null;
    gate?.complete();
    if (_status.state == AudioSessionState.paused) {
      _setState(AudioSessionState.active);
    }
  }

  void _releasePause() {
    _explicitlyPaused = false;
    _consumerPaused = false;
    final Completer<void>? gate = _resumeGate;
    _resumeGate = null;
    gate?.complete();
  }

  void _throwIfCancelled(AudioCancellationToken? operationToken) {
    _request.cancellation?.throwIfCancelled();
    operationToken?.throwIfCancelled();
  }

  void _throwIfStale(int generation) {
    if (_isStale(generation)) {
      throw AudioCancelledException(
        _lifecycleCancellation.token.cancellation ??
            const AudioCancellation(reason: 'session_stopped'),
      );
    }
  }

  bool _isStale(int generation) =>
      generation != _generation || _stopRequested || _closing;

  void _attachCancellation(
    AudioCancellationToken? token, {
    bool requestCancellation = false,
  }) {
    if (token == null) {
      return;
    }
    if (requestCancellation) {
      if (_requestCancellationAttached) {
        return;
      }
      _requestCancellationAttached = true;
    }
    if (token.isCancelled) {
      _lifecycleCancellation.cancel(
        token.cancellation ?? const AudioCancellation(),
      );
      return;
    }
    unawaited(
      token.whenCancelled
          .then<void>((AudioCancellation cancellation) async {
            _lifecycleCancellation.cancel(cancellation);
            try {
              await abort();
            } on Object {
              // Session status and the start/pump futures retain the failure.
            }
          })
          .catchError((Object _) {
            // The cancellation callback intentionally has no error channel.
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
    _releasePause();
  }

  Future<void> _captureStart(_FirstError errors) async {
    final Future<void>? startFuture = _startFuture;
    if (startFuture == null) {
      return;
    }
    try {
      await startFuture;
    } on AudioCancelledException {
      // Expected after stop/abort/close rejects a stale startup.
    } catch (error, stackTrace) {
      errors.add(error, stackTrace);
    }
  }

  void _publishFailure(AudioFailure failure, StackTrace stackTrace) {
    if (_status.state == AudioSessionState.closed) {
      return;
    }
    if (!_framesClosed) {
      _frames.addError(failure, stackTrace);
    }
    _setState(AudioSessionState.failed, failure: failure);
  }

  void _ensureOpen() {
    if (_closing || _status.state == AudioSessionState.closed) {
      throw StateError('OpenAI TTS session is closed.');
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

const int _maximumWavHeaderBytes = 1024 * 1024;
const int _wavHeaderReadQuantum = 4096;

abstract interface class _StreamingAudioDecoder {
  Future<void> add(Uint8List bytes);

  Future<void> finish();
}

final class _StreamingFrameEmitter {
  factory _StreamingFrameEmitter(_OpenAiTtsSession session) {
    final int configuredFrames = session.format.framesForDuration(
      session._provider.config.frameDuration,
    );
    final int frameSize =
        (configuredFrames < 1 ? 1 : configuredFrames) * session.format.channels;
    return _StreamingFrameEmitter._(session, frameSize);
  }

  _StreamingFrameEmitter._(this._session, this._frameSize)
    : _buffer = Float32List(_frameSize);

  final _OpenAiTtsSession _session;
  final int _frameSize;
  final Float32List _buffer;
  int _length = 0;
  int _sequence = 0;
  int _sampleOffset = 0;
  bool _discarded = false;

  Future<void> addPcm16(Uint8List bytes, {int start = 0, int? end}) async {
    if (_discarded) {
      return;
    }
    final int endOffset = end ?? bytes.length;
    if (start < 0 ||
        endOffset < start ||
        endOffset > bytes.length ||
        (endOffset - start).isOdd) {
      throw ArgumentError('PCM byte range must contain complete int16 values.');
    }
    final ByteData data = ByteData.sublistView(bytes);
    var byteOffset = start;
    while (byteOffset < endOffset) {
      final int availableSamples = (endOffset - byteOffset) ~/ 2;
      final int capacity = _frameSize - _length;
      final int take = availableSamples < capacity
          ? availableSamples
          : capacity;
      for (var index = 0; index < take; index += 1) {
        _buffer[_length + index] =
            data.getInt16(byteOffset + index * 2, Endian.little) / 32768;
      }
      _length += take;
      byteOffset += take * 2;
      if (_length == _frameSize) {
        await _flush();
      }
      if (_discarded) {
        return;
      }
    }
  }

  Future<void> addPcm16Value(int lowByte, int highByte) async {
    final Uint8List bytes = Uint8List.fromList(<int>[lowByte, highByte]);
    await addPcm16(bytes);
  }

  Future<void> finish() => _flush();

  Future<void> _flush() async {
    if (_length == 0 || _discarded) {
      return;
    }
    final Float32List samples = Float32List.fromList(
      _buffer.sublist(0, _length),
    );
    final bool emitted = await _session._emitFrame(
      samples,
      _sequence,
      _sampleOffset,
    );
    if (!emitted) {
      _discarded = true;
      _length = 0;
      return;
    }
    _sequence += 1;
    _sampleOffset += samples.length ~/ _session.format.channels;
    _length = 0;
  }
}

final class _StreamingPcm16Decoder implements _StreamingAudioDecoder {
  _StreamingPcm16Decoder(this._emitter);

  final _StreamingFrameEmitter _emitter;
  int? _pendingByte;

  @override
  Future<void> add(Uint8List bytes) async {
    var offset = 0;
    final int? pendingByte = _pendingByte;
    if (pendingByte != null && bytes.isNotEmpty) {
      _pendingByte = null;
      await _emitter.addPcm16Value(pendingByte, bytes[0]);
      offset = 1;
    }
    final int completeEnd = bytes.length - ((bytes.length - offset) & 1);
    if (completeEnd > offset) {
      await _emitter.addPcm16(bytes, start: offset, end: completeEnd);
    }
    if (completeEnd < bytes.length) {
      _pendingByte = bytes.last;
    }
  }

  @override
  Future<void> finish() async {
    if (_pendingByte != null) {
      throw _failure(
        code: 'openai_pcm_invalid',
        message: 'OpenAI returned truncated PCM audio.',
        retryable: false,
      );
    }
    await _emitter.finish();
  }
}

final class _StreamingWavDecoder implements _StreamingAudioDecoder {
  _StreamingWavDecoder({
    required this.expectedFormat,
    required _StreamingFrameEmitter emitter,
    required this.maximumHeaderBytes,
  }) : _pcm = _StreamingPcm16Decoder(emitter);

  final AudioFormat expectedFormat;
  final int maximumHeaderBytes;
  final _StreamingPcm16Decoder _pcm;
  final List<int> _header = <int>[];
  bool _foundData = false;
  int _remainingDataBytes = 0;

  @override
  Future<void> add(Uint8List bytes) async {
    if (_foundData) {
      await _consumeData(bytes);
      return;
    }

    var inputOffset = 0;
    while (!_foundData && inputOffset < bytes.length) {
      final int room = maximumHeaderBytes - _header.length;
      if (room <= 0) {
        throw _failure(
          code: 'openai_wav_header_too_large',
          message: 'OpenAI returned a WAV header that is too large.',
          retryable: false,
        );
      }
      final int remainingInput = bytes.length - inputOffset;
      final int quantum = room < _wavHeaderReadQuantum
          ? room
          : _wavHeaderReadQuantum;
      final int take = remainingInput < quantum ? remainingInput : quantum;
      _header.addAll(
        Uint8List.sublistView(bytes, inputOffset, inputOffset + take),
      );
      inputOffset += take;

      final _WavDataHeader? parsed = _parseWavHeader(_header, expectedFormat);
      if (parsed == null) {
        if (_header.length >= maximumHeaderBytes) {
          throw _failure(
            code: 'openai_wav_header_too_large',
            message: 'OpenAI returned a WAV header that is too large.',
            retryable: false,
          );
        }
        continue;
      }

      _foundData = true;
      _remainingDataBytes = parsed.dataLength;
      if (_header.length > parsed.dataOffset) {
        await _consumeData(
          Uint8List.fromList(_header.sublist(parsed.dataOffset)),
        );
      }
      _header.clear();
    }

    if (_foundData && inputOffset < bytes.length) {
      await _consumeData(Uint8List.sublistView(bytes, inputOffset));
    }
  }

  Future<void> _consumeData(Uint8List bytes) async {
    if (_remainingDataBytes <= 0 || bytes.isEmpty) {
      return;
    }
    final int take = bytes.length < _remainingDataBytes
        ? bytes.length
        : _remainingDataBytes;
    await _pcm.add(Uint8List.sublistView(bytes, 0, take));
    _remainingDataBytes -= take;
  }

  @override
  Future<void> finish() async {
    if (!_foundData) {
      throw _failure(
        code: 'openai_wav_invalid',
        message: 'OpenAI returned invalid WAV audio.',
        retryable: false,
      );
    }
    if (_remainingDataBytes != 0) {
      throw _failure(
        code: 'openai_wav_invalid',
        message: 'OpenAI returned truncated WAV audio.',
        retryable: false,
      );
    }
    await _pcm.finish();
  }
}

final class _WavDataHeader {
  const _WavDataHeader({required this.dataOffset, required this.dataLength});

  final int dataOffset;
  final int dataLength;
}

_WavDataHeader? _parseWavHeader(List<int> bytes, AudioFormat expectedFormat) {
  if (bytes.length < 12) {
    return null;
  }
  if (!_matchesAscii(bytes, 0, 'RIFF') || !_matchesAscii(bytes, 8, 'WAVE')) {
    throw _failure(
      code: 'openai_wav_invalid',
      message: 'OpenAI returned invalid WAV audio.',
      retryable: false,
    );
  }
  final int riffEnd = _uint32(bytes, 4) + 8;
  var offset = 12;
  _WavFormatChunk? formatChunk;
  while (true) {
    if (bytes.length < offset + 8) {
      return null;
    }
    final String chunkId = String.fromCharCodes(
      bytes.sublist(offset, offset + 4),
    );
    final int chunkLength = _uint32(bytes, offset + 4);
    final int payloadOffset = offset + 8;
    final int paddedEnd = payloadOffset + chunkLength + (chunkLength & 1);
    if (chunkId == 'data') {
      final _WavFormatChunk? parsedFormat = formatChunk;
      if (parsedFormat == null) {
        throw _failure(
          code: 'openai_wav_invalid',
          message: 'OpenAI returned WAV audio without a format chunk.',
          retryable: false,
        );
      }
      _validateWavFormat(parsedFormat, expectedFormat);
      if (chunkLength % parsedFormat.blockAlign != 0 ||
          (riffEnd != 0x100000007 && paddedEnd > riffEnd)) {
        throw _failure(
          code: 'openai_wav_invalid',
          message: 'OpenAI returned invalid WAV audio.',
          retryable: false,
        );
      }
      return _WavDataHeader(dataOffset: payloadOffset, dataLength: chunkLength);
    }
    if (chunkId == 'fmt ' && chunkLength < 16) {
      throw _failure(
        code: 'openai_wav_invalid',
        message: 'OpenAI returned an invalid WAV format chunk.',
        retryable: false,
      );
    }
    if (bytes.length < paddedEnd) {
      return null;
    }
    if (chunkId == 'fmt ') {
      formatChunk = _WavFormatChunk(
        encoding: _uint16(bytes, payloadOffset),
        channels: _uint16(bytes, payloadOffset + 2),
        sampleRate: _uint32(bytes, payloadOffset + 4),
        byteRate: _uint32(bytes, payloadOffset + 8),
        blockAlign: _uint16(bytes, payloadOffset + 12),
        bitsPerSample: _uint16(bytes, payloadOffset + 14),
      );
    }
    offset = paddedEnd;
    if (riffEnd != 0x100000007 && offset > riffEnd) {
      throw _failure(
        code: 'openai_wav_invalid',
        message: 'OpenAI returned invalid WAV audio.',
        retryable: false,
      );
    }
  }
}

final class _WavFormatChunk {
  const _WavFormatChunk({
    required this.encoding,
    required this.channels,
    required this.sampleRate,
    required this.byteRate,
    required this.blockAlign,
    required this.bitsPerSample,
  });

  final int encoding;
  final int channels;
  final int sampleRate;
  final int byteRate;
  final int blockAlign;
  final int bitsPerSample;
}

void _validateWavFormat(_WavFormatChunk actual, AudioFormat expected) {
  if (actual.encoding != 1 || actual.bitsPerSample != 16) {
    throw _failure(
      code: 'openai_wav_encoding_unsupported',
      message: 'OpenAI returned an unsupported WAV encoding.',
      retryable: false,
    );
  }
  if (actual.channels != expected.channels ||
      actual.sampleRate != expected.sampleRate) {
    throw _failure(
      code: 'openai_audio_format_changed',
      message: 'OpenAI returned an unexpected audio format.',
      retryable: false,
    );
  }
  final int expectedBlockAlign = actual.channels * 2;
  if (actual.blockAlign != expectedBlockAlign ||
      actual.byteRate != actual.sampleRate * expectedBlockAlign) {
    throw _failure(
      code: 'openai_wav_invalid',
      message: 'OpenAI returned an inconsistent WAV format.',
      retryable: false,
    );
  }
}

bool _matchesAscii(List<int> bytes, int offset, String expected) {
  for (var index = 0; index < expected.length; index += 1) {
    if (bytes[offset + index] != expected.codeUnitAt(index)) {
      return false;
    }
  }
  return true;
}

int _uint16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _uint32(List<int> bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

final class _FirstError {
  Object? _error;
  StackTrace? _stackTrace;

  Future<void> capture(FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (error, stackTrace) {
      add(error, stackTrace);
    }
  }

  void add(Object error, StackTrace stackTrace) {
    _error ??= error;
    _stackTrace ??= stackTrace;
  }

  void throwIfPresent() {
    if (_error case final Object error) {
      Error.throwWithStackTrace(error, _stackTrace!);
    }
  }
}

AudioFailure _failureForResponse(OpenAiTtsTransportResponse response) {
  final bool retryable =
      response.statusCode == 408 ||
      response.statusCode == 409 ||
      response.statusCode == 429 ||
      response.statusCode >= 500;
  return _failure(
    code: 'openai_http_${response.statusCode}',
    message: switch (response.statusCode) {
      401 || 403 => 'OpenAI rejected the synthesis credential.',
      429 => 'OpenAI is temporarily rate limiting synthesis.',
      >= 500 => 'OpenAI synthesis is temporarily unavailable.',
      _ => 'OpenAI rejected the synthesis request.',
    },
    retryable: retryable,
  );
}

AudioFailure _failure({
  required String code,
  required String message,
  Object? cause,
  bool retryable = true,
}) => AudioFailure(
  code: code,
  stage: AudioFailureStage.provider,
  providerId: OpenAiTextToSpeechProvider.providerId,
  message: message,
  retryable: retryable,
  safeCause: cause?.runtimeType.toString(),
);

String _titleCase(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
