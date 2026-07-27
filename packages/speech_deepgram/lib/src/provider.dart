import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'auth.dart';
import 'io_transport.dart';
import 'options.dart';
import 'transport.dart';

/// Provider-neutral Deepgram streaming speech recognition.
final class DeepgramSpeechToTextProvider extends IdempotentSpeechProvider
    implements StreamingSpeechToTextProvider {
  factory DeepgramSpeechToTextProvider({
    required DeepgramTokenSource tokenSource,
    DeepgramTransportFactory transportFactory =
        const IoDeepgramTransportFactory(),
    DeepgramProviderConfig? config,
  }) => DeepgramSpeechToTextProvider._(
    tokenSource,
    transportFactory,
    config ?? DeepgramProviderConfig(),
  );

  DeepgramSpeechToTextProvider._(
    this._tokenSource,
    this._transportFactory,
    this.config,
  ) : descriptor = SpeechProviderDescriptor(
        id: providerId,
        displayName: 'Deepgram',
        capabilities: <SpeechCapability>{
          SpeechCapability.streamingSpeechToText,
        },
        models: <SpeechModelDescriptor>[
          SpeechModelDescriptor(
            id: 'nova-3',
            providerId: providerId,
            displayName: 'Nova 3',
            capabilities: <SpeechCapability>{
              SpeechCapability.streamingSpeechToText,
            },
          ),
          SpeechModelDescriptor(
            id: 'nova-2',
            providerId: providerId,
            displayName: 'Nova 2',
            capabilities: <SpeechCapability>{
              SpeechCapability.streamingSpeechToText,
            },
          ),
        ],
      );

  /// Stable provider identifier.
  static const String providerId = 'deepgram';

  final DeepgramTokenSource _tokenSource;
  final DeepgramTransportFactory _transportFactory;

  /// Connection and bounded-write settings.
  final DeepgramProviderConfig config;

  final Set<_DeepgramStreamingSession> _sessions =
      <_DeepgramStreamingSession>{};

  @override
  final SpeechProviderDescriptor descriptor;

  @override
  Future<StreamingSpeechToTextSession> prepareStreamingRecognition(
    StreamingRecognitionRequest request,
  ) async {
    ensureOpen();
    request.cancellation?.throwIfCancelled();
    final DeepgramStreamingOptions options = _optionsFor(request);
    final DeepgramAccessToken token;
    try {
      token = await _tokenSource.getToken(
        cancellationToken: request.cancellation,
      );
      request.cancellation?.throwIfCancelled();
    } on AudioCancelledException {
      rethrow;
    } catch (error) {
      throw SpeechFailure(
        code: 'deepgram_token_failed',
        stage: 'prepare',
        providerId: providerId,
        retryable: true,
        safeMessage: 'A Deepgram access token could not be obtained.',
        safeCause: error.runtimeType.toString(),
      );
    }
    if (token.value.trim().isEmpty || token.isExpired()) {
      throw SpeechFailure(
        code: 'deepgram_token_invalid',
        stage: 'prepare',
        providerId: providerId,
        retryable: true,
        safeMessage: 'The Deepgram access token is unavailable or expired.',
      );
    }

    DeepgramStreamingTransport? transport;
    try {
      transport = await _transportFactory.connect(
        DeepgramTransportRequest(
          uri: _buildUri(request, options),
          authorization:
              '${token.authorizationScheme.headerScheme} ${token.value}',
          pingInterval: config.pingInterval,
          closeTimeout: config.closeTimeout,
        ),
      );
      request.cancellation?.throwIfCancelled();
    } on AudioCancelledException {
      await transport?.close();
      rethrow;
    } catch (error) {
      await transport?.close();
      throw SpeechFailure(
        code: 'deepgram_connect_failed',
        stage: 'prepare',
        providerId: providerId,
        retryable: true,
        safeMessage: 'Deepgram could not be reached.',
        safeCause: error.runtimeType.toString(),
      );
    }

    late final _DeepgramStreamingSession session;
    try {
      session = _DeepgramStreamingSession(
        transport,
        request.inputFormat,
        config.maximumQueuedAudioBytes,
        request.cancellation,
        () {
          _sessions.remove(session);
        },
      );
    } catch (_) {
      await transport.close();
      rethrow;
    }
    _sessions.add(session);
    return session;
  }

  DeepgramStreamingOptions _optionsFor(StreamingRecognitionRequest request) {
    final SpeechProviderOptions? providerOptions =
        request.options.providerOptions;
    if (providerOptions == null) {
      return DeepgramStreamingOptions();
    }
    if (providerOptions is! DeepgramStreamingOptions) {
      throw SpeechFailure(
        code: 'deepgram_options_invalid',
        stage: 'prepare',
        providerId: providerId,
        safeMessage: 'Recognition options do not belong to Deepgram.',
      );
    }
    return providerOptions;
  }

  Uri _buildUri(
    StreamingRecognitionRequest request,
    DeepgramStreamingOptions options,
  ) {
    final SpeechRecognitionOptions generic = request.options;
    final Map<String, Object> parameters = <String, Object>{
      ...config.endpoint.queryParameters,
      'encoding': 'linear16',
      'sample_rate': request.inputFormat.sampleRate.toString(),
      'channels': request.inputFormat.channels.toString(),
      'model': generic.modelId ?? config.defaultModelId,
      'punctuate': generic.punctuate.toString(),
      'interim_results': options.interimResults.toString(),
      'smart_format': options.smartFormat.toString(),
      'vad_events': options.voiceActivityEvents.toString(),
      'endpointing': options.endpointing.inMilliseconds.toString(),
      'profanity_filter': options.profanityFilter.toString(),
      'numerals': options.numerals.toString(),
      'alternatives': generic.maxAlternatives.toString(),
    };
    final String? languageTag = generic.languageTag;
    if (languageTag != null && !options.detectLanguage) {
      parameters['language'] = languageTag;
    }
    if (options.detectLanguage) {
      parameters['detect_language'] = 'true';
    }
    final Duration? utteranceEnd = options.utteranceEnd;
    if (utteranceEnd != null) {
      parameters['utterance_end_ms'] = utteranceEnd.inMilliseconds.toString();
    }
    final DeepgramDiarizationModel? diarizationModel = options.diarizationModel;
    if (diarizationModel != null) {
      parameters['diarize_model'] = diarizationModel.wireName;
    }
    final String? tag = options.tag;
    if (tag != null && tag.trim().isNotEmpty) {
      parameters['tag'] = tag;
    }
    if (generic.vocabulary.isNotEmpty) {
      final String modelId = generic.modelId ?? config.defaultModelId;
      parameters[_usesKeyterms(modelId) ? 'keyterm' : 'keywords'] =
          generic.vocabulary;
    }
    return config.endpoint.replace(queryParameters: parameters);
  }

  @override
  Future<void> onClose() async {
    final List<_DeepgramStreamingSession> sessions =
        List<_DeepgramStreamingSession>.of(_sessions);
    try {
      await Future.wait<void>(sessions.map((session) => session.close()));
    } finally {
      _sessions.clear();
    }
  }
}

final class _DeepgramStreamingSession implements StreamingSpeechToTextSession {
  _DeepgramStreamingSession(
    this._transport,
    this.format,
    this.maximumQueuedAudioBytes,
    this._requestCancellation,
    this._onClosed,
  ) : _status = const AudioSessionStatus(
        state: AudioSessionState.prepared,
        timestamp: Duration.zero,
      ) {
    _clock.start();
    _transportSubscription = _transport.events.listen(
      _onTransportEvent,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(_failTransport(error, stackTrace));
      },
    );
    final AudioCancellationToken? requestCancellation = _requestCancellation;
    if (requestCancellation != null) {
      unawaited(requestCancellation.whenCancelled.then<void>((_) => abort()));
    }
  }

  final DeepgramStreamingTransport _transport;
  final AudioCancellationToken? _requestCancellation;
  final void Function() _onClosed;

  @override
  final AudioFormat format;

  final int maximumQueuedAudioBytes;
  final StreamController<SpeechRecognitionEvent> _results =
      StreamController<SpeechRecognitionEvent>.broadcast();
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast();
  final Stopwatch _clock = Stopwatch();

  late final StreamSubscription<DeepgramTransportEvent> _transportSubscription;
  late AudioSessionStatus _status;
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _finishFuture;
  Future<void>? _abortFuture;
  Future<void>? _failureFuture;
  Future<void>? _closeFuture;
  int _queuedAudioBytes = 0;
  int _partialRevision = 0;
  int _finalSegment = 0;
  String? _sourceId;
  String? _trackId;
  String? _clockId;
  int? _expectedSequence;
  int? _expectedSampleOffset;
  Duration? _previousTimestamp;
  bool _resultsClosed = false;
  bool _transportCloseExpected = false;

  @override
  AudioSinkCapabilities get capabilities => AudioSinkCapabilities.sequential;

  @override
  Stream<SpeechRecognitionEvent> get results => _results.stream;

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
    _ensureWritable();
    if (_status.state == AudioSessionState.prepared) {
      _setState(AudioSessionState.active);
    }
    _throwIfCancelled(cancellationToken);
    if (frame.format != format) {
      throw ArgumentError.value(
        frame.format,
        'frame',
        'Frame format must match the prepared Deepgram format $format.',
      );
    }
    final AudioFailure? continuityFailure = _validateContinuity(frame);
    if (continuityFailure != null) {
      unawaited(_fail(continuityFailure, StackTrace.current));
      return Future<void>.error(continuityFailure, StackTrace.current);
    }
    final Uint8List bytes = _encodeLinear16(frame.samples);
    if (_queuedAudioBytes + bytes.length > maximumQueuedAudioBytes) {
      final AudioFailure failure = AudioFailure(
        code: 'deepgram_audio_queue_overflow',
        stage: AudioFailureStage.provider,
        providerId: DeepgramSpeechToTextProvider.providerId,
        message: 'Deepgram could not consume audio within its queue bound.',
        retryable: true,
      );
      unawaited(_fail(failure, StackTrace.current));
      return Future<void>.error(failure, StackTrace.current);
    }
    _sourceId ??= frame.sourceId;
    _trackId ??= frame.trackId;
    _clockId ??= frame.clockId;
    _expectedSequence = frame.sequence + 1;
    _expectedSampleOffset = frame.endSampleOffset;
    _previousTimestamp = frame.timestamp;
    _queuedAudioBytes += bytes.length;
    final Future<void> operation = _writeTail.then<void>((_) async {
      try {
        _throwIfCancelled(cancellationToken);
        _ensureWritable();
        await _transport.sendAudio(bytes);
        _throwIfCancelled(cancellationToken);
      } on AudioCancelledException {
        rethrow;
      } catch (error, stackTrace) {
        final AudioFailure failure = _audioFailure(
          code: 'deepgram_write_failed',
          message: 'Audio could not be sent to Deepgram.',
          cause: error,
        );
        unawaited(_fail(failure, stackTrace));
        Error.throwWithStackTrace(failure, stackTrace);
      } finally {
        _queuedAudioBytes -= bytes.length;
      }
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace stackTrace) {},
    );
    return operation;
  }

  @override
  Future<void> finish({AudioCancellationToken? cancellationToken}) {
    final Future<void>? existing = _finishFuture;
    if (existing != null) {
      return existing;
    }
    _throwIfCancelled(cancellationToken);
    if (_status.state == AudioSessionState.finished) {
      return Future<void>.value();
    }
    if (_status.state != AudioSessionState.active &&
        _status.state != AudioSessionState.prepared) {
      throw StateError('Deepgram session is not active.');
    }
    _setState(AudioSessionState.finishing);
    return _finishFuture = _finish(cancellationToken);
  }

  Future<void> _finish(AudioCancellationToken? cancellationToken) async {
    try {
      await _writeTail;
      final AudioFailure? pendingFailure = _status.failure;
      if (_status.state == AudioSessionState.failed && pendingFailure != null) {
        throw pendingFailure;
      }
      if (_status.state == AudioSessionState.aborted ||
          _status.state == AudioSessionState.closed) {
        return;
      }
      if (_status.state != AudioSessionState.finishing) {
        return;
      }
      _throwIfCancelled(cancellationToken);
      _transportCloseExpected = true;
      await _transport.finish();
      _throwIfCancelled(cancellationToken);
      if (_status.state == AudioSessionState.finishing) {
        _setState(AudioSessionState.finished);
      }
      await _closeResults();
    } on AudioCancelledException {
      await abort();
      rethrow;
    } catch (error, stackTrace) {
      final AudioFailure failure = error is AudioFailure
          ? error
          : _audioFailure(
              code: 'deepgram_finish_failed',
              message: 'Deepgram recognition could not be finalized.',
              cause: error,
            );
      await _fail(failure, stackTrace);
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  @override
  Future<void> abort({AudioFailure? failure}) {
    final Future<void>? existing = _abortFuture;
    if (existing != null) {
      return existing;
    }
    if (_isTerminal(_status.state)) {
      return Future<void>.value();
    }
    return _abortFuture = _abort(failure);
  }

  Future<void> _abort(AudioFailure? failure) async {
    _transportCloseExpected = true;
    _setState(
      failure == null ? AudioSessionState.aborted : AudioSessionState.failed,
      failure: failure,
    );
    Future<void>? transportAbort;
    try {
      transportAbort = _transport.abort();
    } on Object {
      // Abort is best-effort.
    }
    await _closeResults();
    try {
      await transportAbort;
    } on Object {
      // Lifecycle and result streams are already terminal.
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _doClose();

  Future<void> _doClose() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    if (!_isTerminal(_status.state)) {
      try {
        await abort();
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    }
    for (final Future<void>? operation in <Future<void>?>[
      _finishFuture,
      _abortFuture,
      _failureFuture,
      _writeTail,
    ]) {
      try {
        await operation;
      } catch (_) {
        // Operational failures are reported by their initiating calls and
        // stable session status; cleanup continues independently.
      }
    }
    try {
      await _transportSubscription.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _transport.close();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _closeResults();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _setState(AudioSessionState.closed);
    if (!_statuses.isClosed) {
      unawaited(_statuses.close());
    }
    _clock.stop();
    _onClosed();
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }

  void _onTransportEvent(DeepgramTransportEvent event) {
    switch (event) {
      case DeepgramTransportText(:final text):
        _handleText(text);
      case DeepgramTransportClosed(:final code):
        if (!_transportCloseExpected && !_isTerminal(_status.state)) {
          unawaited(
            _fail(
              _audioFailure(
                code: 'deepgram_connection_closed',
                message: 'The Deepgram connection closed unexpectedly.',
                cause: code == null ? null : 'websocket code $code',
              ),
              StackTrace.current,
            ),
          );
        }
      case DeepgramTransportError(:final error, :final stackTrace):
        unawaited(_failTransport(error, stackTrace ?? StackTrace.current));
    }
  }

  void _handleText(String text) {
    if (_resultsClosed || _isTerminal(_status.state)) {
      return;
    }
    final Map<String, Object?> message;
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Expected a JSON object.');
      }
      message = decoded;
    } catch (error, stackTrace) {
      unawaited(
        _fail(
          _audioFailure(
            code: 'deepgram_response_invalid',
            message: 'Deepgram returned an invalid response.',
            cause: error,
            retryable: false,
          ),
          stackTrace,
        ),
      );
      return;
    }
    final String? type = _string(message['type']);
    switch (type) {
      case 'Results':
        _handleResults(message);
      case 'SpeechStarted':
        _results.add(
          RecognitionSpeechStarted(at: _seconds(message['timestamp'])),
        );
      case 'UtteranceEnd':
        _results.add(
          RecognitionSpeechEnded(at: _seconds(message['last_word_end'])),
        );
      case 'Error':
        final String providerCode =
            _string(message['variant']) ??
            _string(message['code']) ??
            'unknown';
        final SpeechFailure failure = SpeechFailure(
          code: 'deepgram_provider_error',
          stage: 'recognition',
          providerId: DeepgramSpeechToTextProvider.providerId,
          retryable: _providerErrorIsRetryable(providerCode),
          safeMessage: 'Deepgram could not complete recognition.',
        );
        _results.add(RecognitionFailed(failure: failure, at: _clock.elapsed));
        unawaited(
          _fail(
            _audioFailure(
              code: 'deepgram_provider_error',
              message: failure.safeMessage,
              cause: providerCode,
              retryable: failure.retryable,
            ),
            StackTrace.current,
            emitRecognitionFailure: false,
          ),
        );
      default:
        break;
    }
  }

  void _handleResults(Map<String, Object?> message) {
    final Map<String, Object?>? channel = _objectMap(message['channel']);
    final List<Object?> alternatives = _objectList(channel?['alternatives']);
    if (alternatives.isEmpty) {
      return;
    }
    final Map<String, Object?>? alternative = _objectMap(alternatives.first);
    if (alternative == null) {
      return;
    }
    final String transcriptText = _string(alternative['transcript']) ?? '';
    final bool isFinal = _boolean(message['is_final']) ?? false;
    final bool speechFinal = _boolean(message['speech_final']) ?? false;
    final Duration start = _seconds(message['start']);
    final Duration duration = _seconds(message['duration']);
    final Duration at = start + duration;

    if (transcriptText.isNotEmpty) {
      final SpeechTranscript transcript = SpeechTranscript(
        text: transcriptText,
        words: _parseWords(alternative['words']),
        languageTag:
            _string(message['language']) ?? _string(alternative['language']),
        confidence: _probability(alternative['confidence']),
      );
      if (isFinal) {
        _finalSegment += 1;
        _results.add(
          RecognitionFinal(
            transcript: transcript,
            segmentId: 'deepgram-$_finalSegment',
            at: at,
          ),
        );
      } else {
        _partialRevision += 1;
        _results.add(
          RecognitionPartial(
            transcript: transcript,
            revision: _partialRevision,
            at: at,
          ),
        );
      }
    }
    if (speechFinal) {
      _results.add(RecognitionSpeechEnded(at: at));
    }
  }

  List<SpeechWord> _parseWords(Object? value) {
    final List<SpeechWord> words = <SpeechWord>[];
    for (final Object? item in _objectList(value)) {
      final Map<String, Object?>? word = _objectMap(item);
      if (word == null) {
        continue;
      }
      final String? text =
          _string(word['punctuated_word']) ?? _string(word['word']);
      if (text == null || text.isEmpty) {
        continue;
      }
      final Duration start = _seconds(word['start']);
      final Duration end = _seconds(word['end']);
      if (end < start) {
        continue;
      }
      words.add(
        SpeechWord(
          text: text,
          range: SpeechTimeRange(start: start, end: end),
          confidence: _probability(word['confidence']),
          speakerId: _speakerId(word['speaker']),
        ),
      );
    }
    return words;
  }

  Future<void> _failTransport(Object error, StackTrace stackTrace) => _fail(
    _audioFailure(
      code: 'deepgram_transport_failed',
      message: 'The Deepgram connection failed.',
      cause: error,
    ),
    stackTrace,
  );

  Future<void> _fail(
    AudioFailure failure,
    StackTrace stackTrace, {
    bool emitRecognitionFailure = true,
  }) {
    final Future<void>? existing = _failureFuture;
    if (existing != null) {
      return existing;
    }
    if (_isTerminal(_status.state)) {
      return Future<void>.value();
    }
    return _failureFuture = _failOnce(
      failure,
      stackTrace,
      emitRecognitionFailure: emitRecognitionFailure,
    );
  }

  Future<void> _failOnce(
    AudioFailure failure,
    StackTrace stackTrace, {
    required bool emitRecognitionFailure,
  }) async {
    if (emitRecognitionFailure && !_resultsClosed) {
      _results.add(
        RecognitionFailed(
          failure: SpeechFailure(
            code: failure.code,
            stage: 'recognition',
            providerId: DeepgramSpeechToTextProvider.providerId,
            retryable: failure.retryable,
            safeMessage: failure.message,
            safeCause: failure.safeCause,
          ),
          at: _clock.elapsed,
        ),
      );
    }
    _transportCloseExpected = true;
    _setState(AudioSessionState.failed, failure: failure);
    try {
      await _transport.abort();
    } on Object {
      // Preserve the first stable provider failure.
    }
    await _closeResults();
  }

  Future<void> _closeResults() {
    if (_resultsClosed) {
      return Future<void>.value();
    }
    _resultsClosed = true;
    if (!_results.isClosed) {
      unawaited(_results.close());
    }
    return Future<void>.value();
  }

  void _throwIfCancelled(AudioCancellationToken? operationToken) {
    _requestCancellation?.throwIfCancelled();
    operationToken?.throwIfCancelled();
  }

  void _ensureWritable() {
    if (_status.state != AudioSessionState.prepared &&
        _status.state != AudioSessionState.active) {
      throw StateError('Deepgram session is not accepting audio.');
    }
  }

  AudioFailure? _validateContinuity(AudioFrame frame) {
    if (frame.discontinuity != null) {
      return _audioFailure(
        code: 'deepgram_audio_discontinuity',
        message: 'Deepgram requires a contiguous primary audio route.',
        retryable: true,
      );
    }
    final String? sourceId = _sourceId;
    if (sourceId != null &&
        (frame.sourceId != sourceId ||
            frame.trackId != _trackId ||
            frame.clockId != _clockId)) {
      return _audioFailure(
        code: 'deepgram_audio_stream_changed',
        message: 'Deepgram cannot change audio streams within one session.',
        retryable: false,
      );
    }
    final int? expectedSequence = _expectedSequence;
    final int? expectedSampleOffset = _expectedSampleOffset;
    final Duration? previousTimestamp = _previousTimestamp;
    if ((expectedSequence != null && frame.sequence != expectedSequence) ||
        (expectedSampleOffset != null &&
            frame.sampleOffset != expectedSampleOffset) ||
        (previousTimestamp != null && frame.timestamp < previousTimestamp)) {
      return _audioFailure(
        code: 'deepgram_audio_out_of_order',
        message: 'Deepgram received non-contiguous or out-of-order audio.',
        retryable: false,
      );
    }
    return null;
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

Uint8List _encodeLinear16(Float32List samples) {
  final ByteData data = ByteData(samples.length * 2);
  for (var index = 0; index < samples.length; index += 1) {
    final double value = samples[index].clamp(-1.0, 1.0);
    final int encoded = value < 0
        ? (value * 32768).round()
        : (value * 32767).round();
    data.setInt16(index * 2, encoded, Endian.little);
  }
  return data.buffer.asUint8List();
}

AudioFailure _audioFailure({
  required String code,
  required String message,
  Object? cause,
  bool retryable = true,
}) => AudioFailure(
  code: code,
  stage: AudioFailureStage.provider,
  providerId: DeepgramSpeechToTextProvider.providerId,
  message: message,
  retryable: retryable,
  safeCause: cause?.runtimeType.toString(),
);

Map<String, Object?>? _objectMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map<String, dynamic>) {
    return value.cast<String, Object?>();
  }
  return null;
}

List<Object?> _objectList(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  if (value is List<dynamic>) {
    return value.cast<Object?>();
  }
  return const <Object?>[];
}

String? _string(Object? value) => value is String ? value : null;

bool? _boolean(Object? value) => value is bool ? value : null;

double? _number(Object? value) => value is num ? value.toDouble() : null;

double? _probability(Object? value) {
  final double? number = _number(value);
  if (number == null || !number.isFinite || number < 0 || number > 1) {
    return null;
  }
  return number;
}

Duration _seconds(Object? value) {
  final double seconds = _number(value) ?? 0;
  if (!seconds.isFinite || seconds <= 0) {
    return Duration.zero;
  }
  return Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).round(),
  );
}

String? _speakerId(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  if (value is num) {
    return value.toString();
  }
  return null;
}

bool _providerErrorIsRetryable(String code) {
  final String normalized = code.toLowerCase();
  return normalized.contains('rate') ||
      normalized.contains('unavailable') ||
      normalized.contains('timeout') ||
      normalized.contains('internal');
}

bool _usesKeyterms(String modelId) {
  final String normalized = modelId.toLowerCase();
  return normalized.startsWith('nova-3') || normalized.startsWith('flux');
}
