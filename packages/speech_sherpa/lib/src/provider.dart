import 'dart:async';
import 'dart:typed_data';

import 'package:speech_core/speech_core.dart';

import 'conversion.dart';
import 'failure.dart';
import 'model_registry.dart';
import 'models.dart';
import 'native_runtime.dart';
import 'options.dart';
import 'runtime.dart';
import 'sessions.dart';

/// Cross-platform speech provider backed by sherpa-onnx.
///
/// Covers streaming and batch recognition, voice-activity detection,
/// diarization, and the speaker vectors behind it, on every platform Flutter
/// targets. The two recognition paths use different models and different
/// sherpa recognizers, so [transcribe] and [prepareStreamingRecognition]
/// resolve from disjoint halves of the catalog.
final class SherpaSpeechProvider extends IdempotentSpeechProvider
    implements
        StreamingSpeechToTextProvider,
        BatchSpeechToTextProvider,
        VoiceActivityDetectionProvider,
        BatchDiarizationProvider {
  /// Creates a provider that resolves models through [registry].
  ///
  /// Tests inject [runtime] to exercise provider behavior without ONNX
  /// Runtime, model files, or isolates.
  SherpaSpeechProvider({
    required this.registry,
    SherpaRuntime? runtime,
    this.maximumBatchAudioDuration = const Duration(hours: 4),
  }) : _runtime = runtime ?? SherpaNativeRuntime();

  /// Resolves and installs the model files this provider loads.
  final SherpaModelRegistry registry;

  /// Longest 16 kHz mono audio accepted by one batch operation.
  final Duration maximumBatchAudioDuration;

  final SherpaRuntime _runtime;
  final Set<SherpaManagedSession> _sessions = <SherpaManagedSession>{};

  SherpaBatchAsrDriver? _asrDriver;
  String? _asrModelId;
  SherpaDiarizationDriver? _diarizationDriver;

  int get _maximumBatchSamples =>
      (maximumBatchAudioDuration.inMicroseconds * sherpaSampleRate) ~/
      Duration.microsecondsPerSecond;

  @override
  SpeechProviderDescriptor get descriptor => _descriptor;

  static final SpeechProviderDescriptor _descriptor = buildSherpaDescriptor();

  /// Resolves the batch catalog entry for [modelId], defaulting when absent.
  static SherpaRecognitionModel resolveRecognitionModel(String? modelId) =>
      _resolveModel(
        modelId: modelId,
        candidates: SherpaRecognitionModel.batchModels,
        fallback: SherpaRecognitionModel.defaultModel,
        description: 'a batch recognition model',
      );

  /// Resolves the streaming catalog entry for [modelId], defaulting when
  /// absent.
  static SherpaRecognitionModel resolveStreamingModel(String? modelId) =>
      _resolveModel(
        modelId: modelId,
        candidates: SherpaRecognitionModel.streamingModels,
        fallback: SherpaRecognitionModel.defaultStreamingModel,
        description: 'a streaming recognition model',
      );

  static SherpaRecognitionModel _resolveModel({
    required String? modelId,
    required List<SherpaRecognitionModel> candidates,
    required SherpaRecognitionModel fallback,
    required String description,
  }) {
    if (modelId == null) {
      return fallback;
    }
    for (final model in candidates) {
      if (model.id == modelId) {
        return model;
      }
    }
    throw sherpaSpeechFailure(
      'sherpa_unknown_model',
      'prepare',
      'The requested model is not $description in the sherpa-onnx catalog.',
    );
  }

  @override
  Future<BatchRecognitionResult> transcribe(
    BatchRecognitionRequest request,
  ) async {
    ensureOpen();
    final options = request.options;
    final providerOptions = _recognitionOptions(options.providerOptions);
    final model = resolveRecognitionModel(options.modelId);

    final paths = registry.resolveRecognition(model);
    if (paths == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_not_installed',
        'prepare',
        'The ${model.displayName} model is not installed.',
      );
    }

    final driver = await _obtainAsrDriver(
      model: model,
      paths: paths,
      options: providerOptions,
      languageCode: sherpaLanguageCode(options.languageTag),
    );

    final audio = await collectSherpaAudio(
      request.audio,
      maximumConvertedSamples: _maximumBatchSamples,
      cancellation: request.cancellation,
      onProgress: request.onProgress,
    );
    request.cancellation?.throwIfCancelled();

    if (audio.samples.isEmpty) {
      request.onProgress?.call(1);
      return BatchRecognitionResult(text: '');
    }

    final transcript = await driver.transcribe(audio.samples);
    request.cancellation?.throwIfCancelled();
    request.onProgress?.call(1);

    final text = transcript.text.trim();
    return BatchRecognitionResult(
      text: text,
      languageTag: transcript.languageCode ?? options.languageTag,
      segments: text.isEmpty
          ? const <BatchRecognitionSegment>[]
          : <BatchRecognitionSegment>[
              BatchRecognitionSegment(
                text: text,
                start: Duration.zero,
                end: audio.duration,
              ),
            ],
    );
  }

  @override
  Future<StreamingSpeechToTextSession> prepareStreamingRecognition(
    StreamingRecognitionRequest request,
  ) async {
    ensureOpen();
    final options = request.options;
    final providerOptions = _streamingOptions(options.providerOptions);
    final model = resolveStreamingModel(options.modelId);

    final paths = registry.resolveRecognition(model);
    if (paths == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_not_installed',
        'prepare',
        'The ${model.displayName} model is not installed.',
      );
    }

    final driver = await _runtime.createStreamingAsr(
      buildStreamingAsrConfiguration(paths: paths, options: providerOptions),
    );

    final session = SherpaStreamingRecognitionSession(
      onClosed: _sessions.remove,
      format: request.inputFormat,
      driver: driver,
      // A monolingual model knows its own language better than the request
      // does; only a multilingual one has anything to learn from the caller.
      languageTag:
          options.languageTag ??
          (model.languageTags.length == 1 ? model.languageTags.single : null),
      cancellation: request.cancellation,
    );
    _sessions.add(session);
    return session;
  }

  @override
  Future<BatchDiarizationResult> diarize(
    BatchDiarizationRequest request,
  ) async {
    ensureOpen();
    final options = _diarizationOptions(request.providerOptions);
    final paths = registry.resolveDiarization();
    if (paths == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_not_installed',
        'prepare',
        'The diarization models are not installed.',
      );
    }

    final exactSpeakers =
        request.minimumSpeakers != null &&
            request.minimumSpeakers == request.maximumSpeakers
        ? request.minimumSpeakers
        : null;

    final driver = await _obtainDiarizationDriver(
      paths: paths,
      options: options,
      exactSpeakerCount: exactSpeakers,
    );

    final audio = await collectSherpaAudio(
      request.audio,
      maximumConvertedSamples: _maximumBatchSamples,
      cancellation: request.cancellation,
    );
    request.cancellation?.throwIfCancelled();
    if (audio.samples.isEmpty) {
      return BatchDiarizationResult(segments: const <SpeakerSegment>[]);
    }

    final spans = await driver.diarize(audio.samples);
    request.cancellation?.throwIfCancelled();

    final segments = <SpeakerSegment>[
      for (final span in spans)
        SpeakerSegment(
          speakerId: 'speaker-${span.speaker}',
          range: SpeechTimeRange(
            start: _seconds(span.startSeconds),
            end: _seconds(span.endSeconds),
          ),
          embedding: _embeddingFor(span.embedding, paths.embeddingModelId),
        ),
    ]..sort((a, b) => a.range.start.compareTo(b.range.start));

    return BatchDiarizationResult(segments: segments);
  }

  @override
  Future<VoiceActivityDetectionSession> prepareVoiceActivityDetection(
    VoiceActivityDetectionRequest request,
  ) async {
    ensureOpen();
    final options = _voiceActivityOptions(request.providerOptions);
    final modelPath = registry.resolveVad();
    if (modelPath == null) {
      throw sherpaSpeechFailure(
        'sherpa_model_not_installed',
        'prepare',
        'The Silero VAD model is not installed.',
      );
    }

    final driver = await _runtime.createVad(
      SherpaVadConfiguration(
        modelPath: modelPath,
        threshold: request.startThreshold,
        minimumSilenceSeconds: _toSeconds(request.minimumSilence),
        minimumSpeechSeconds: _toSeconds(request.minimumSpeech),
        maximumSpeechSeconds: _toSeconds(options.maximumSpeech),
        windowSize: options.windowSize,
        numThreads: options.numThreads,
        bufferSizeSeconds: _toSeconds(options.bufferSize),
      ),
    );

    final session = SherpaVoiceActivitySession(
      onClosed: _sessions.remove,
      format: request.inputFormat,
      driver: driver,
      cancellation: request.cancellation,
    );
    _sessions.add(session);
    return session;
  }

  Future<SherpaBatchAsrDriver> _obtainAsrDriver({
    required SherpaRecognitionModel model,
    required SherpaRecognitionModelPaths paths,
    required SherpaRecognitionOptions options,
    String? languageCode,
  }) async {
    final existing = _asrDriver;
    if (existing != null && _asrModelId == model.id) {
      return existing;
    }
    // Switching models frees the previous weights first: two resident
    // recognizers is over a gigabyte for no benefit.
    if (existing != null) {
      _asrDriver = null;
      _asrModelId = null;
      await existing.close();
    }
    final driver = await _runtime.createBatchAsr(
      buildBatchAsrConfiguration(
        paths: paths,
        options: options,
        languageCode: languageCode,
      ),
    );
    _asrDriver = driver;
    _asrModelId = model.id;
    return driver;
  }

  Future<SherpaDiarizationDriver> _obtainDiarizationDriver({
    required SherpaDiarizationModelPaths paths,
    required SherpaDiarizationOptions options,
    int? exactSpeakerCount,
  }) async {
    final existing = _diarizationDriver;
    if (existing != null) {
      return existing;
    }
    final driver = await _runtime.createDiarizer(
      buildDiarizationConfiguration(
        paths: paths,
        options: options,
        exactSpeakerCount: exactSpeakerCount,
      ),
    );
    _diarizationDriver = driver;
    return driver;
  }

  /// Releases the recognizer weights while keeping the provider usable.
  ///
  /// Recognition models are hundreds of megabytes; an app that records
  /// intermittently should not hold them between sessions.
  Future<void> unloadRecognizer() async {
    final driver = _asrDriver;
    _asrDriver = null;
    _asrModelId = null;
    await driver?.close();
  }

  /// Releases the diarizer while keeping the provider usable.
  Future<void> unloadDiarizer() async {
    final driver = _diarizationDriver;
    _diarizationDriver = null;
    await driver?.close();
  }

  @override
  Future<void> onClose() async {
    for (final session in List<SherpaManagedSession>.of(_sessions)) {
      await session.close();
    }
    _sessions.clear();
    await unloadRecognizer();
    await unloadDiarizer();
    await _runtime.close();
  }

  SpeakerEmbedding? _embeddingFor(Float32List? vector, String modelId) {
    if (vector == null || vector.isEmpty) {
      return null;
    }
    for (final value in vector) {
      if (!value.isFinite) {
        return null;
      }
    }
    // L2-normalize here so a stored centroid is a valid cosine reference.
    return SpeakerEmbedding.normalized(
      providerId: sherpaProviderId,
      modelId: modelId,
      vector: vector,
    );
  }

  SherpaRecognitionOptions _recognitionOptions(SpeechProviderOptions? value) =>
      switch (value) {
        null => SherpaRecognitionOptions(),
        final SherpaRecognitionOptions options => options,
        _ => throw sherpaSpeechFailure(
          'sherpa_invalid_options',
          'prepare',
          'The supplied provider options belong to another provider.',
        ),
      };

  SherpaStreamingRecognitionOptions _streamingOptions(
    SpeechProviderOptions? value,
  ) => switch (value) {
    null => SherpaStreamingRecognitionOptions(),
    final SherpaStreamingRecognitionOptions options => options,
    // Batch options reach here when a caller reuses one request's options for
    // the other path; the endpointing rules have no batch equivalent to read.
    _ => throw sherpaSpeechFailure(
      'sherpa_invalid_options',
      'prepare',
      'A streaming session requires SherpaStreamingRecognitionOptions.',
    ),
  };

  SherpaDiarizationOptions _diarizationOptions(SpeechProviderOptions? value) =>
      switch (value) {
        null => SherpaDiarizationOptions(),
        final SherpaDiarizationOptions options => options,
        _ => throw sherpaSpeechFailure(
          'sherpa_invalid_options',
          'prepare',
          'The supplied provider options belong to another provider.',
        ),
      };

  SherpaVoiceActivityOptions _voiceActivityOptions(
    SpeechProviderOptions? value,
  ) => switch (value) {
    null => SherpaVoiceActivityOptions(),
    final SherpaVoiceActivityOptions options => options,
    _ => throw sherpaSpeechFailure(
      'sherpa_invalid_options',
      'prepare',
      'The supplied provider options belong to another provider.',
    ),
  };
}

Duration _seconds(double value) => Duration(
  microseconds: (value * Duration.microsecondsPerSecond).round().clamp(
    0,
    1 << 62,
  ),
);

double _toSeconds(Duration value) =>
    value.inMicroseconds / Duration.microsecondsPerSecond;
