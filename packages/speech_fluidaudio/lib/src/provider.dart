import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'conversion.dart';
import 'drivers.dart';
import 'native_runtime.dart';
import 'options.dart';
import 'session_support.dart';
import 'sessions.dart';
import 'tts_source.dart';

/// Provider-neutral FluidAudio speech implementation.
final class FluidAudioSpeechProvider extends IdempotentSpeechProvider
    implements
        StreamingSpeechToTextProvider,
        BatchSpeechToTextProvider,
        VoiceActivityDetectionProvider,
        EndOfUtteranceProvider,
        BatchDiarizationProvider,
        TextToSpeechProvider,
        CustomizableInverseTextNormalizer {
  /// Creates a provider backed by [runtime].
  ///
  /// Tests and alternative transports can inject an adapter-owned runtime;
  /// production defaults to the `fluidaudio_dart` plugin.
  FluidAudioSpeechProvider({
    FluidAudioRuntime? runtime,
    this.maximumBatchAudioDuration = const Duration(minutes: 30),
  }) : _runtime = runtime ?? FluidNativeRuntime() {
    if (maximumBatchAudioDuration <= Duration.zero ||
        (maximumBatchAudioDuration.inMicroseconds * 16000) <
            Duration.microsecondsPerSecond) {
      throw ArgumentError.value(
        maximumBatchAudioDuration,
        'maximumBatchAudioDuration',
        'Must contain at least one 16 kHz sample.',
      );
    }
  }

  final FluidAudioRuntime _runtime;
  final Set<FluidManagedSession> _sessions = <FluidManagedSession>{};
  Future<FluidItnDriver>? _itnDriver;

  /// Maximum converted 16 kHz mono audio retained for one batch operation.
  final Duration maximumBatchAudioDuration;

  int get _maximumBatchAudioSamples =>
      (maximumBatchAudioDuration.inMicroseconds * 16000) ~/
      Duration.microsecondsPerSecond;

  @override
  SpeechProviderDescriptor get descriptor => _descriptor;

  static final SpeechProviderDescriptor _descriptor = SpeechProviderDescriptor(
    id: fluidAudioProviderId,
    displayName: 'FluidAudio',
    capabilities: const <SpeechCapability>{
      SpeechCapability.streamingSpeechToText,
      SpeechCapability.batchSpeechToText,
      SpeechCapability.voiceActivityDetection,
      SpeechCapability.endOfUtterance,
      SpeechCapability.diarization,
      SpeechCapability.speakerEmbedding,
      SpeechCapability.textToSpeech,
      SpeechCapability.inverseTextNormalization,
    },
    models: <SpeechModelDescriptor>[
      SpeechModelDescriptor(
        id: FluidRecognitionModel.parakeetV2.id,
        providerId: fluidAudioProviderId,
        displayName: 'Parakeet v2',
        capabilities: const <SpeechCapability>{
          SpeechCapability.streamingSpeechToText,
          SpeechCapability.batchSpeechToText,
        },
        languageTags: const <String>{'en'},
        isLocal: true,
      ),
      SpeechModelDescriptor(
        id: FluidRecognitionModel.parakeetV3.id,
        providerId: fluidAudioProviderId,
        displayName: 'Parakeet v3',
        capabilities: const <SpeechCapability>{
          SpeechCapability.streamingSpeechToText,
          SpeechCapability.batchSpeechToText,
        },
        isLocal: true,
      ),
      SpeechModelDescriptor(
        id: 'silero-vad',
        providerId: fluidAudioProviderId,
        displayName: 'Silero VAD',
        capabilities: const <SpeechCapability>{
          SpeechCapability.voiceActivityDetection,
        },
        isLocal: true,
      ),
      SpeechModelDescriptor(
        id: 'eou',
        providerId: fluidAudioProviderId,
        displayName: 'FluidAudio EOU',
        capabilities: const <SpeechCapability>{SpeechCapability.endOfUtterance},
        isLocal: true,
      ),
      SpeechModelDescriptor(
        id: fluidDiarizationModelId,
        providerId: fluidAudioProviderId,
        displayName: 'FluidAudio VBx Diarization',
        capabilities: const <SpeechCapability>{
          SpeechCapability.diarization,
          SpeechCapability.speakerEmbedding,
        },
        isLocal: true,
      ),
      SpeechModelDescriptor(
        id: 'itn',
        providerId: fluidAudioProviderId,
        displayName: 'FluidAudio Inverse Text Normalization',
        capabilities: const <SpeechCapability>{
          SpeechCapability.inverseTextNormalization,
        },
        languageTags: const <String>{'en'},
        isLocal: true,
      ),
      SpeechModelDescriptor(
        id: 'pocket-tts',
        providerId: fluidAudioProviderId,
        displayName: 'PocketTTS',
        capabilities: const <SpeechCapability>{SpeechCapability.textToSpeech},
        isLocal: true,
      ),
      SpeechModelDescriptor(
        id: 'kokoro-english',
        providerId: fluidAudioProviderId,
        displayName: 'Kokoro English',
        capabilities: const <SpeechCapability>{SpeechCapability.textToSpeech},
        isLocal: true,
      ),
      SpeechModelDescriptor(
        id: 'kokoro-mandarin',
        providerId: fluidAudioProviderId,
        displayName: 'Kokoro Mandarin',
        capabilities: const <SpeechCapability>{SpeechCapability.textToSpeech},
        languageTags: const <String>{'zh'},
        isLocal: true,
      ),
      SpeechModelDescriptor(
        id: 'kokoro-japanese',
        providerId: fluidAudioProviderId,
        displayName: 'Kokoro Japanese',
        capabilities: const <SpeechCapability>{SpeechCapability.textToSpeech},
        languageTags: const <String>{'ja'},
        isLocal: true,
      ),
    ],
    voices: <SpeechVoiceDescriptor>[
      SpeechVoiceDescriptor(
        id: 'af_heart',
        providerId: fluidAudioProviderId,
        displayName: 'Heart',
        languageTags: const <String>{'en'},
        isLocal: true,
      ),
    ],
  );

  @override
  Future<StreamingSpeechToTextSession> prepareStreamingRecognition(
    StreamingRecognitionRequest request,
  ) async {
    ensureOpen();
    request.cancellation?.throwIfCancelled();
    final options = _recognitionOptions(request.options);
    final model = _recognitionModel(request.options.modelId, options.model);
    _validateRecognitionLanguage(model, request.options.languageTag);
    final vocabulary = _mergedVocabulary(
      request.options.vocabulary,
      options.vocabulary,
    );

    FluidStreamingAsrDriver? driver;
    FluidStreamingSpeechToTextSession? session;
    try {
      driver = await _runtime.createStreamingAsr(
        FluidStreamingAsrDriverConfiguration(
          model: model,
          source: options.source,
          chunkSeconds: options.chunkSeconds,
          hypothesisChunkSeconds: options.hypothesisChunkSeconds,
          leftContextSeconds: options.leftContextSeconds,
          rightContextSeconds: options.rightContextSeconds,
          minimumContextForConfirmation: options.minimumContextForConfirmation,
          confirmationThreshold: options.confirmationThreshold,
          vocabulary: vocabulary,
          vocabularyMinimumSimilarity: options.vocabularyMinimumSimilarity,
        ),
      );
      request.cancellation?.throwIfCancelled();
      ensureOpen();
      session = FluidStreamingSpeechToTextSession(
        driver: driver,
        format: request.inputFormat,
        languageTag: request.options.languageTag,
        cancellation: request.cancellation,
        onClosed: _unregisterSession,
      );
      _registerSession(session);

      // The adapter listener is installed by the session constructor. Starting
      // afterwards prevents the native EventChannel startup race.
      await driver.start();
      request.cancellation?.throwIfCancelled();
      return session;
    } catch (error) {
      await session?.close();
      await driver?.close();
      throw fluidSpeechFailure(
        error is AudioCancelledException
            ? 'fluid_cancelled'
            : 'fluid_asr_prepare_failed',
        'prepare',
        error is AudioCancelledException
            ? 'FluidAudio streaming recognition preparation was cancelled.'
            : 'FluidAudio streaming recognition could not be prepared.',
        cause: error,
      );
    }
  }

  @override
  Future<BatchRecognitionResult> transcribe(
    BatchRecognitionRequest request,
  ) async {
    ensureOpen();
    request.cancellation?.throwIfCancelled();
    final options = _recognitionOptions(request.options);
    final model = _recognitionModel(request.options.modelId, options.model);
    _validateRecognitionLanguage(model, request.options.languageTag);
    if (request.options.vocabulary.isNotEmpty ||
        options.vocabulary.isNotEmpty) {
      throw fluidSpeechFailure(
        'fluid_batch_vocabulary_unsupported',
        'prepare',
        'FluidAudio custom vocabulary is available only for streaming '
            'recognition.',
      );
    }

    FluidBatchAsrDriver? driver;
    try {
      final audio = await collectFluidAudio(
        request.audio,
        cancellation: request.cancellation,
        onProgress: request.onProgress,
        maximumConvertedSamples: _maximumBatchAudioSamples,
      );
      if (audio.samples.isEmpty) {
        throw fluidSpeechFailure(
          'fluid_empty_audio',
          'recognition',
          'The recognition source did not produce audio.',
        );
      }
      ensureOpen();
      driver = await _runtime.createBatchAsr(model);
      final result = await _withCancellation(
        driver.transcribe(
          audio.samples,
          language: fluidLanguageCode(request.options.languageTag),
        ),
        request.cancellation,
        driver.close,
      );
      request.onProgress?.call(1);
      final duration = result.duration == Duration.zero
          ? audio.duration
          : result.duration;
      return BatchRecognitionResult(
        text: result.text,
        languageTag: request.options.languageTag,
        segments: <BatchRecognitionSegment>[
          if (result.text.trim().isNotEmpty)
            BatchRecognitionSegment(
              text: result.text,
              start: Duration.zero,
              end: duration,
            ),
        ],
      );
    } catch (error) {
      throw fluidSpeechFailure(
        error is AudioCancelledException
            ? 'fluid_cancelled'
            : 'fluid_batch_asr_failed',
        'recognition',
        error is AudioCancelledException
            ? 'The FluidAudio transcription was cancelled.'
            : 'FluidAudio could not transcribe the audio.',
        cause: error,
      );
    } finally {
      await driver?.close();
    }
  }

  @override
  Future<VoiceActivityDetectionSession> prepareVoiceActivityDetection(
    VoiceActivityDetectionRequest request,
  ) async {
    ensureOpen();
    request.cancellation?.throwIfCancelled();
    _requireNoUnexpectedOptions(request.providerOptions);
    if (!request.startThreshold.isFinite ||
        !request.endThreshold.isFinite ||
        request.startThreshold < 0 ||
        request.startThreshold > 1 ||
        request.endThreshold < 0 ||
        request.endThreshold > 1 ||
        request.minimumSpeech.isNegative ||
        request.minimumSilence.isNegative) {
      throw fluidSpeechFailure(
        'fluid_invalid_options',
        'prepare',
        'The FluidAudio VAD thresholds or durations are invalid.',
      );
    }
    FluidVadDriver? driver;
    FluidVoiceActivityDetectionSession? session;
    try {
      driver = await _runtime.createVad(
        threshold: request.startThreshold,
        minimumSilence: request.minimumSilence,
      );
      request.cancellation?.throwIfCancelled();
      ensureOpen();
      session = FluidVoiceActivityDetectionSession(
        driver: driver,
        format: request.inputFormat,
        startThreshold: request.startThreshold,
        endThreshold: request.endThreshold,
        minimumSpeech: request.minimumSpeech,
        minimumSilence: request.minimumSilence,
        cancellation: request.cancellation,
        onClosed: _unregisterSession,
      );
      _registerSession(session);
      return session;
    } catch (error) {
      await session?.close();
      await driver?.close();
      throw fluidSpeechFailure(
        error is AudioCancelledException
            ? 'fluid_cancelled'
            : 'fluid_vad_prepare_failed',
        'prepare',
        error is AudioCancelledException
            ? 'FluidAudio VAD preparation was cancelled.'
            : 'FluidAudio voice activity detection could not be prepared.',
        cause: error,
      );
    }
  }

  @override
  Future<EndOfUtteranceSession> prepareEndOfUtterance(
    EndOfUtteranceRequest request,
  ) async {
    ensureOpen();
    request.cancellation?.throwIfCancelled();
    final options =
        _typedOptions<FluidEndOfUtteranceOptions>(request.providerOptions) ??
        FluidEndOfUtteranceOptions();
    if (options.debounce.isNegative) {
      throw fluidSpeechFailure(
        'fluid_invalid_options',
        'prepare',
        'FluidAudio EOU debounce must not be negative.',
      );
    }

    FluidEndOfUtteranceDriver? driver;
    FluidEndOfUtteranceSession? session;
    try {
      driver = await _runtime.createEndOfUtterance(
        chunk: options.chunk,
        debounce: options.debounce,
      );
      request.cancellation?.throwIfCancelled();
      ensureOpen();
      session = FluidEndOfUtteranceSession(
        driver: driver,
        format: request.inputFormat,
        cancellation: request.cancellation,
        onClosed: _unregisterSession,
      );
      _registerSession(session);
      return session;
    } catch (error) {
      await session?.close();
      await driver?.close();
      throw fluidSpeechFailure(
        error is AudioCancelledException
            ? 'fluid_cancelled'
            : 'fluid_eou_prepare_failed',
        'prepare',
        error is AudioCancelledException
            ? 'FluidAudio turn-detection preparation was cancelled.'
            : 'FluidAudio end-of-utterance detection could not be prepared.',
        cause: error,
      );
    }
  }

  @override
  Future<BatchDiarizationResult> diarize(
    BatchDiarizationRequest request,
  ) async {
    ensureOpen();
    request.cancellation?.throwIfCancelled();
    final options =
        _typedOptions<FluidDiarizationOptions>(request.providerOptions) ??
        FluidDiarizationOptions();
    if (!options.clusteringThreshold.isFinite ||
        options.clusteringThreshold < 0 ||
        options.clusteringThreshold > 1) {
      throw fluidSpeechFailure(
        'fluid_invalid_options',
        'prepare',
        'The FluidAudio diarization clustering threshold is invalid.',
      );
    }
    _validateSpeakerBounds(
      request.minimumSpeakers,
      request.maximumSpeakers,
      options.exactSpeakerCount,
    );

    FluidDiarizationDriver? driver;
    try {
      final audio = await collectFluidAudio(
        request.audio,
        cancellation: request.cancellation,
        maximumConvertedSamples: _maximumBatchAudioSamples,
      );
      if (audio.samples.isEmpty) {
        throw fluidSpeechFailure(
          'fluid_empty_audio',
          'diarization',
          'The diarization source did not produce audio.',
        );
      }
      ensureOpen();
      driver = await _runtime.createDiarizer(
        FluidDiarizationDriverConfiguration(
          clusteringThreshold: options.clusteringThreshold,
          exactSpeakerCount: options.exactSpeakerCount,
          minimumSpeakers: request.minimumSpeakers,
          maximumSpeakers: request.maximumSpeakers,
        ),
      );
      final segments = await _withCancellation(
        driver.diarize(audio.samples),
        request.cancellation,
        driver.close,
      );
      return BatchDiarizationResult(
        segments: <SpeakerSegment>[
          for (final segment in segments)
            if (!segment.start.isNegative && segment.end >= segment.start)
              SpeakerSegment(
                speakerId: segment.speakerId,
                range: SpeechTimeRange(start: segment.start, end: segment.end),
                confidence: _safeProviderConfidence(segment.confidence),
                embedding: _speakerEmbedding(segment.embedding),
              ),
        ],
      );
    } catch (error) {
      throw fluidSpeechFailure(
        error is AudioCancelledException
            ? 'fluid_cancelled'
            : 'fluid_diarization_failed',
        'diarization',
        error is AudioCancelledException
            ? 'The FluidAudio diarization was cancelled.'
            : 'FluidAudio could not diarize the audio.',
        cause: error,
      );
    } finally {
      await driver?.close();
    }
  }

  @override
  AudioSource synthesize(SpeechSynthesisRequest request) {
    ensureOpen();
    request.cancellation?.throwIfCancelled();
    if (request.text.trim().isEmpty) {
      throw fluidSpeechFailure(
        'fluid_empty_text',
        'synthesis',
        'Text-to-speech input must not be empty.',
      );
    }
    if (request.pitch != 0) {
      throw fluidSpeechFailure(
        'fluid_pitch_unsupported',
        'synthesis',
        'FluidAudio does not support pitch adjustment.',
      );
    }
    final typed =
        _typedOptions<FluidSynthesisOptions>(request.providerOptions) ??
        FluidSynthesisOptions();
    if (!typed.temperature.isFinite ||
        typed.temperature < 0 ||
        typed.temperature > 2 ||
        !request.rate.isFinite ||
        request.rate <= 0 ||
        !request.pitch.isFinite) {
      throw fluidSpeechFailure(
        'fluid_invalid_options',
        'synthesis',
        'The FluidAudio synthesis parameters are invalid.',
      );
    }
    final engine = _synthesisEngine(request.modelId, typed.engine);
    if (engine == FluidSynthesisEngine.pocket && request.rate != 1) {
      throw fluidSpeechFailure(
        'fluid_pocket_rate_unsupported',
        'synthesis',
        'PocketTTS does not support speaking-rate adjustment.',
      );
    }
    return FluidTtsAudioSource(
      runtime: _runtime,
      text: request.text,
      voice: request.voiceId,
      rate: request.rate,
      configuration: FluidTtsDriverConfiguration(
        engine: engine,
        temperature: typed.temperature,
      ),
      ensureProviderOpen: ensureOpen,
      registerSession: _registerSession,
      onSessionClosed: _unregisterSession,
      requestCancellation: request.cancellation,
    );
  }

  @override
  Future<String> normalize(String text, {String? languageTag}) async {
    ensureOpen();
    _validateNormalizationLanguage(languageTag);
    if (text.trim().isEmpty) {
      return text;
    }
    final driver = await _inverseTextNormalizer();
    try {
      return await driver.normalizeSentence(text);
    } catch (error) {
      throw fluidSpeechFailure(
        'fluid_itn_failed',
        'normalization',
        'FluidAudio could not normalize the text.',
        cause: error,
      );
    }
  }

  @override
  Future<List<String>> normalizeSentences(
    Iterable<String> sentences, {
    String? languageTag,
  }) async {
    ensureOpen();
    _validateNormalizationLanguage(languageTag);
    final inputs = List<String>.of(sentences);
    if (inputs.isEmpty) {
      return const <String>[];
    }
    final driver = await _inverseTextNormalizer();
    final normalized = <String>[];
    try {
      for (final sentence in inputs) {
        // Blank input has no spoken form to rewrite, and skipping it keeps the
        // one-result-per-input contract without a native round trip.
        normalized.add(
          sentence.trim().isEmpty
              ? sentence
              : await driver.normalizeSentence(sentence),
        );
      }
    } catch (error) {
      throw fluidSpeechFailure(
        'fluid_itn_failed',
        'normalization',
        'FluidAudio could not normalize the text.',
        cause: error,
      );
    }
    return List<String>.unmodifiable(normalized);
  }

  @override
  Future<void> addRule(InverseTextNormalizationRule rule) async {
    ensureOpen();
    final driver = await _inverseTextNormalizer();
    try {
      await driver.addRule(spoken: rule.spoken, written: rule.written);
    } catch (error) {
      throw fluidSpeechFailure(
        'fluid_itn_rule_failed',
        'normalization',
        'FluidAudio could not register the normalization rule.',
        cause: error,
      );
    }
  }

  @override
  Future<void> onClose() async {
    final sessions = List<FluidManagedSession>.of(_sessions);
    Object? firstFailure;
    StackTrace? firstStackTrace;
    try {
      for (final session in sessions) {
        try {
          await session.close();
        } catch (error, stackTrace) {
          firstFailure ??= error;
          firstStackTrace ??= stackTrace;
        }
      }
    } finally {
      _sessions.clear();
    }
    final pendingItn = _itnDriver;
    _itnDriver = null;
    if (pendingItn != null) {
      try {
        await (await pendingItn).close();
      } catch (error, stackTrace) {
        firstFailure ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    try {
      await _runtime.close();
    } catch (error, stackTrace) {
      firstFailure ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (firstFailure != null) {
      Error.throwWithStackTrace(
        firstFailure,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }

  /// Loads the ITN driver once and reuses it for the provider's lifetime.
  ///
  /// A failed load is not cached, so a later call retries rather than replaying
  /// a stale error — the native normalization library can become available
  /// after a model install.
  Future<FluidItnDriver> _inverseTextNormalizer() async {
    ensureOpen();
    final pending = _itnDriver ??= _runtime.createItn();
    try {
      return await pending;
    } catch (error) {
      if (identical(_itnDriver, pending)) {
        _itnDriver = null;
      }
      throw fluidSpeechFailure(
        'fluid_itn_unavailable',
        'prepare',
        'FluidAudio inverse text normalization is unavailable.',
        cause: error,
      );
    }
  }

  void _validateNormalizationLanguage(String? languageTag) {
    final language = fluidLanguageCode(languageTag);
    if (language != null && language != 'en') {
      throw fluidSpeechFailure(
        'fluid_language_unsupported',
        'normalization',
        'FluidAudio inverse text normalization supports English text only.',
      );
    }
  }

  FluidRecognitionOptions _recognitionOptions(
    SpeechRecognitionOptions options,
  ) =>
      _typedOptions<FluidRecognitionOptions>(options.providerOptions) ??
      FluidRecognitionOptions();

  T? _typedOptions<T extends SpeechProviderOptions>(
    SpeechProviderOptions? options,
  ) {
    if (options == null) {
      return null;
    }
    if (options.providerId != fluidAudioProviderId || options is! T) {
      throw fluidSpeechFailure(
        'fluid_invalid_options',
        'prepare',
        'The provider options are not valid for this FluidAudio operation.',
      );
    }
    return options;
  }

  void _requireNoUnexpectedOptions(SpeechProviderOptions? options) {
    if (options != null) {
      throw fluidSpeechFailure(
        'fluid_invalid_options',
        'prepare',
        'FluidAudio VAD uses the provider-neutral VAD request options.',
      );
    }
  }

  FluidRecognitionModel _recognitionModel(
    String? requested,
    FluidRecognitionModel fallback,
  ) {
    if (requested == null) {
      return fallback;
    }
    for (final model in FluidRecognitionModel.values) {
      if (model.id == requested) {
        return model;
      }
    }
    throw fluidSpeechFailure(
      'fluid_unknown_model',
      'prepare',
      'The requested FluidAudio recognition model is not available.',
    );
  }

  FluidSynthesisEngine _synthesisEngine(
    String? requested,
    FluidSynthesisEngine fallback,
  ) {
    if (requested == null) {
      return fallback;
    }
    return switch (requested) {
      'pocket-tts' => FluidSynthesisEngine.pocket,
      'kokoro-english' => FluidSynthesisEngine.kokoroEnglish,
      'kokoro-mandarin' => FluidSynthesisEngine.kokoroMandarin,
      'kokoro-japanese' => FluidSynthesisEngine.kokoroJapanese,
      _ => throw fluidSpeechFailure(
        'fluid_unknown_model',
        'synthesis',
        'The requested FluidAudio synthesis model is not available.',
      ),
    };
  }

  void _validateRecognitionLanguage(
    FluidRecognitionModel model,
    String? languageTag,
  ) {
    final language = fluidLanguageCode(languageTag);
    if (model == FluidRecognitionModel.parakeetV2 &&
        language != null &&
        language != 'en') {
      throw fluidSpeechFailure(
        'fluid_language_unsupported',
        'prepare',
        'Parakeet v2 supports English audio only.',
      );
    }
  }

  List<FluidVocabularyEntry> _mergedVocabulary(
    List<String> core,
    List<FluidVocabularyEntry> typed,
  ) {
    final values = <String, FluidVocabularyEntry>{};
    for (final entry in typed) {
      values[entry.text.trim().toLowerCase()] = entry;
    }
    for (final text in core) {
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) {
        values.putIfAbsent(
          trimmed.toLowerCase(),
          () => FluidVocabularyEntry(trimmed),
        );
      }
    }
    return List<FluidVocabularyEntry>.unmodifiable(values.values);
  }

  void _validateSpeakerBounds(int? minimum, int? maximum, int? exact) {
    if ((minimum != null && minimum <= 0) ||
        (maximum != null && maximum <= 0) ||
        (minimum != null && maximum != null && minimum > maximum) ||
        (exact != null &&
            ((minimum != null && exact < minimum) ||
                (maximum != null && exact > maximum)))) {
      throw fluidSpeechFailure(
        'fluid_invalid_speaker_bounds',
        'prepare',
        'The requested FluidAudio speaker bounds are invalid.',
      );
    }
  }

  void _registerSession(FluidManagedSession session) {
    ensureOpen();
    _sessions.add(session);
  }

  void _unregisterSession(FluidManagedSession session) {
    _sessions.remove(session);
  }
}

Future<T> _withCancellation<T>(
  Future<T> operation,
  AudioCancellationToken? cancellation,
  Future<void> Function() onCancel,
) {
  if (cancellation == null) {
    return operation;
  }
  cancellation.throwIfCancelled();
  final cancelled = cancellation.whenCancelled.then<T>((value) {
    unawaited(
      onCancel().then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    throw AudioCancelledException(value);
  });
  return Future.any<T>(<Future<T>>[operation, cancelled]);
}

double? _safeProviderConfidence(double? value) {
  if (value == null || !value.isFinite) {
    return null;
  }
  return value.clamp(0, 1).toDouble();
}

/// Attaches this adapter's embedding-space provenance to a raw diarizer vector.
///
/// FluidAudio's VBx vectors are not normalized on the way out, so they are
/// normalized here to satisfy `SpeakerEmbedding`'s contract. A vector that is
/// empty or contains a non-finite value is dropped rather than surfaced: a
/// half-valid embedding would be persisted into a voice profile and quietly
/// poison every later comparison.
SpeakerEmbedding? _speakerEmbedding(Float32List? vector) {
  if (vector == null || vector.isEmpty) {
    return null;
  }
  for (final value in vector) {
    if (!value.isFinite) {
      return null;
    }
  }
  return SpeakerEmbedding.normalized(
    providerId: fluidAudioProviderId,
    modelId: fluidDiarizationModelId,
    vector: vector,
  );
}
