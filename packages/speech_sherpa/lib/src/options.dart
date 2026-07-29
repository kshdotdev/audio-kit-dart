import 'package:speech_core/speech_core.dart';

/// Stable provider ID for every descriptor and embedding produced here.
const String sherpaProviderId = 'sherpa';

/// Decoding family of a sherpa-onnx recognition model.
///
/// The family selects which sub-config of sherpa's `OfflineModelConfig` is
/// populated; it is not passed to sherpa as `modelType`. See
/// [SherpaRecognitionModel] for why that field stays empty.
enum SherpaRecognitionModelKind {
  /// Encoder/decoder/joiner transducer, such as NeMo Parakeet or k2 Zipformer.
  transducer,

  /// Whisper encoder/decoder pair.
  whisper,

  /// Chunked encoder/decoder/joiner transducer decoded incrementally.
  ///
  /// Loaded by sherpa's `OnlineRecognizer` rather than `OfflineRecognizer`.
  /// The two are not interchangeable: a streaming export carries chunk and
  /// left-context state the offline recognizer cannot drive, and an offline
  /// export has no notion of a partial hypothesis.
  streamingTransducer,
}

/// Typed advanced options for sherpa-onnx recognition.
final class SherpaRecognitionOptions implements SpeechProviderOptions {
  /// Creates recognition options.
  SherpaRecognitionOptions({
    this.numThreads = 4,
    this.decodingMethod = 'greedy_search',
    this.provider = 'cpu',
  }) {
    if (numThreads < 1) {
      throw ArgumentError.value(numThreads, 'numThreads', 'Must be positive.');
    }
    if (decodingMethod.trim().isEmpty) {
      throw ArgumentError.value(
        decodingMethod,
        'decodingMethod',
        'Must not be empty.',
      );
    }
    if (provider.trim().isEmpty) {
      throw ArgumentError.value(provider, 'provider', 'Must not be empty.');
    }
  }

  @override
  String get providerId => sherpaProviderId;

  /// ONNX Runtime intra-op thread count.
  final int numThreads;

  /// sherpa decoding method, such as `greedy_search`.
  final String decodingMethod;

  /// ONNX Runtime execution provider, such as `cpu`.
  final String provider;
}

/// Typed advanced options for sherpa-onnx streaming recognition.
///
/// The three silence rules are sherpa's own endpointing rules, renamed here
/// for what they mean. They are timers over decoder state, not a model: see
/// [enableEndpoint].
final class SherpaStreamingRecognitionOptions implements SpeechProviderOptions {
  /// Creates streaming recognition options.
  SherpaStreamingRecognitionOptions({
    this.numThreads = 2,
    this.decodingMethod = 'greedy_search',
    this.provider = 'cpu',
    this.enableEndpoint = true,
    this.silenceBeforeSpeech = const Duration(milliseconds: 2400),
    this.silenceAfterSpeech = const Duration(milliseconds: 1200),
    this.maximumUtterance = const Duration(seconds: 20),
  }) {
    if (numThreads < 1) {
      throw ArgumentError.value(numThreads, 'numThreads', 'Must be positive.');
    }
    if (decodingMethod.trim().isEmpty) {
      throw ArgumentError.value(
        decodingMethod,
        'decodingMethod',
        'Must not be empty.',
      );
    }
    if (provider.trim().isEmpty) {
      throw ArgumentError.value(provider, 'provider', 'Must not be empty.');
    }
    if (silenceBeforeSpeech.isNegative) {
      throw ArgumentError.value(
        silenceBeforeSpeech,
        'silenceBeforeSpeech',
        'Must not be negative.',
      );
    }
    if (silenceAfterSpeech.isNegative) {
      throw ArgumentError.value(
        silenceAfterSpeech,
        'silenceAfterSpeech',
        'Must not be negative.',
      );
    }
    if (maximumUtterance <= Duration.zero) {
      throw ArgumentError.value(
        maximumUtterance,
        'maximumUtterance',
        'Must be positive.',
      );
    }
  }

  @override
  String get providerId => sherpaProviderId;

  /// ONNX Runtime intra-op thread count.
  ///
  /// Lower than the batch default: a streaming step decodes a fraction of a
  /// second of audio, so thread setup starts to cost more than it saves.
  final int numThreads;

  /// sherpa decoding method, such as `greedy_search`.
  final String decodingMethod;

  /// ONNX Runtime execution provider, such as `cpu`.
  final String provider;

  /// Whether sherpa's rule-based endpointer segments the stream.
  ///
  /// This is not an end-of-utterance model. It fires on silence timers and an
  /// utterance-length cap, so it cannot tell a thinking pause from a finished
  /// thought. Use a real end-of-utterance provider when that distinction
  /// matters; this only decides where one confirmed segment ends.
  final bool enableEndpoint;

  /// Trailing silence that ends a segment before any speech was decoded.
  ///
  /// sherpa's endpointing rule 1.
  final Duration silenceBeforeSpeech;

  /// Trailing silence that ends a segment after speech was decoded.
  ///
  /// sherpa's endpointing rule 2, and the one that governs conversational
  /// turn boundaries in practice.
  final Duration silenceAfterSpeech;

  /// Longest segment before the endpointer cuts regardless of silence.
  ///
  /// sherpa's endpointing rule 3.
  final Duration maximumUtterance;
}

/// Typed advanced options for sherpa-onnx diarization.
final class SherpaDiarizationOptions implements SpeechProviderOptions {
  /// Creates diarization options.
  ///
  /// Defaults mirror the clustering configuration proven in production by
  /// Control Center: cluster count inferred from the audio, cosine threshold
  /// 0.5, and pyannote's own minimum on/off durations.
  SherpaDiarizationOptions({
    this.clusteringThreshold = 0.5,
    this.minimumDurationOn = const Duration(milliseconds: 300),
    this.minimumDurationOff = const Duration(milliseconds: 500),
    this.numThreads = 2,
    this.maximumEmbeddingAudio = const Duration(seconds: 30),
  }) {
    if (!clusteringThreshold.isFinite || clusteringThreshold <= 0) {
      throw ArgumentError.value(
        clusteringThreshold,
        'clusteringThreshold',
        'Must be finite and positive.',
      );
    }
    if (numThreads < 1) {
      throw ArgumentError.value(numThreads, 'numThreads', 'Must be positive.');
    }
    if (minimumDurationOn <= Duration.zero) {
      throw ArgumentError.value(
        minimumDurationOn,
        'minimumDurationOn',
        'Must be positive.',
      );
    }
    if (minimumDurationOff <= Duration.zero) {
      throw ArgumentError.value(
        minimumDurationOff,
        'minimumDurationOff',
        'Must be positive.',
      );
    }
    if (maximumEmbeddingAudio <= Duration.zero) {
      throw ArgumentError.value(
        maximumEmbeddingAudio,
        'maximumEmbeddingAudio',
        'Must be positive.',
      );
    }
  }

  @override
  String get providerId => sherpaProviderId;

  /// Cosine distance threshold used when the speaker count is inferred.
  final double clusteringThreshold;

  /// Shortest retained speech span.
  final Duration minimumDurationOn;

  /// Shortest silence that separates two spans.
  final Duration minimumDurationOff;

  /// ONNX Runtime intra-op thread count for segmentation.
  final int numThreads;

  /// Audio budget per speaker when computing a representative embedding.
  ///
  /// A speaker who talks for an hour does not produce a better centroid than
  /// one who talks for thirty seconds, so the extractor stops early.
  final Duration maximumEmbeddingAudio;
}

/// Typed advanced options for sherpa-onnx voice-activity detection.
final class SherpaVoiceActivityOptions implements SpeechProviderOptions {
  /// Creates VAD options.
  SherpaVoiceActivityOptions({
    this.windowSize = 512,
    this.numThreads = 1,
    this.bufferSize = const Duration(seconds: 30),
    this.maximumSpeech = const Duration(seconds: 5),
  }) {
    if (windowSize < 1) {
      throw ArgumentError.value(windowSize, 'windowSize', 'Must be positive.');
    }
    if (numThreads < 1) {
      throw ArgumentError.value(numThreads, 'numThreads', 'Must be positive.');
    }
    if (bufferSize <= Duration.zero) {
      throw ArgumentError.value(bufferSize, 'bufferSize', 'Must be positive.');
    }
    if (maximumSpeech <= Duration.zero) {
      throw ArgumentError.value(
        maximumSpeech,
        'maximumSpeech',
        'Must be positive.',
      );
    }
  }

  @override
  String get providerId => sherpaProviderId;

  /// Silero window size in samples. Silero v4 expects 512 at 16 kHz.
  final int windowSize;

  /// ONNX Runtime intra-op thread count.
  final int numThreads;

  /// Ring-buffer capacity retained by the detector.
  final Duration bufferSize;

  /// Longest speech span emitted before a forced cut.
  final Duration maximumSpeech;
}
