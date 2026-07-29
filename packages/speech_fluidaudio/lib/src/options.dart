import 'package:speech_core/speech_core.dart';

/// Stable ID used to register the FluidAudio provider.
const String fluidAudioProviderId = 'fluidaudio';

/// Stable model ID of FluidAudio's VBx diarizer.
///
/// Also names the embedding space of every `SpeakerEmbedding` this adapter
/// emits, so it must stay stable across releases: changing it invalidates every
/// stored voice profile, which is the behaviour the space check is there to
/// make visible.
const String fluidDiarizationModelId = 'vbx-diarization';

/// Parakeet model generation used by FluidAudio recognition.
enum FluidRecognitionModel {
  /// English-only Parakeet v2.
  parakeetV2('parakeet-v2'),

  /// Multilingual Parakeet v3.
  parakeetV3('parakeet-v3');

  const FluidRecognitionModel(this.id);

  /// Stable model identifier.
  final String id;
}

/// Logical origin passed to FluidAudio's streaming recognizer.
enum FluidRecognitionSource {
  /// User microphone audio.
  microphone,

  /// Audio captured from another process or the system mix.
  systemAudio,
}

/// One weighted FluidAudio custom-vocabulary entry.
final class FluidVocabularyEntry {
  FluidVocabularyEntry(
    this.text, {
    this.weight,
    Iterable<String> aliases = const <String>[],
  }) : aliases = List<String>.unmodifiable(aliases) {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'Must not be empty.');
    }
    if (weight != null && (!weight!.isFinite || weight! <= 0)) {
      throw ArgumentError.value(weight, 'weight', 'Must be positive.');
    }
  }

  /// Phrase to boost.
  final String text;

  /// Optional provider-specific boost weight.
  final double? weight;

  /// Alternative spellings or pronunciations.
  final List<String> aliases;
}

/// Typed FluidAudio recognition configuration.
final class FluidRecognitionOptions implements SpeechProviderOptions {
  FluidRecognitionOptions({
    this.model = FluidRecognitionModel.parakeetV3,
    this.source = FluidRecognitionSource.microphone,
    this.chunkSeconds,
    this.hypothesisChunkSeconds,
    this.leftContextSeconds,
    this.rightContextSeconds,
    this.minimumContextForConfirmation,
    this.confirmationThreshold,
    Iterable<FluidVocabularyEntry> vocabulary = const <FluidVocabularyEntry>[],
    this.vocabularyMinimumSimilarity = 0.85,
  }) : vocabulary = List<FluidVocabularyEntry>.unmodifiable(vocabulary) {
    _requirePositive(chunkSeconds, 'chunkSeconds');
    _requirePositive(hypothesisChunkSeconds, 'hypothesisChunkSeconds');
    _requireNonNegative(leftContextSeconds, 'leftContextSeconds');
    _requireNonNegative(rightContextSeconds, 'rightContextSeconds');
    _requireNonNegative(
      minimumContextForConfirmation,
      'minimumContextForConfirmation',
    );
    _requireProbability(confirmationThreshold, 'confirmationThreshold');
    _requireProbability(
      vocabularyMinimumSimilarity,
      'vocabularyMinimumSimilarity',
    );
  }

  @override
  String get providerId => fluidAudioProviderId;

  /// Recognition model generation.
  final FluidRecognitionModel model;

  /// Audio origin tag supplied to the recognizer.
  final FluidRecognitionSource source;

  /// FluidAudio sliding-window chunk length.
  final double? chunkSeconds;

  /// FluidAudio volatile hypothesis interval.
  final double? hypothesisChunkSeconds;

  /// Left context retained around each window.
  final double? leftContextSeconds;

  /// Right context retained around each window.
  final double? rightContextSeconds;

  /// Minimum context before a hypothesis can be promoted.
  final double? minimumContextForConfirmation;

  /// Similarity threshold used to promote a hypothesis.
  final double? confirmationThreshold;

  /// Weighted vocabulary entries in addition to core phrase hints.
  final List<FluidVocabularyEntry> vocabulary;

  /// CTC keyword similarity threshold.
  final double vocabularyMinimumSimilarity;
}

/// FluidAudio end-of-utterance model window.
enum FluidEndOfUtteranceChunk {
  /// 160 ms model input.
  milliseconds160,

  /// 320 ms model input.
  milliseconds320,

  /// 1280 ms model input.
  milliseconds1280,
}

/// Typed FluidAudio end-of-utterance configuration.
final class FluidEndOfUtteranceOptions implements SpeechProviderOptions {
  FluidEndOfUtteranceOptions({
    this.chunk = FluidEndOfUtteranceChunk.milliseconds320,
    this.debounce = const Duration(milliseconds: 1280),
  }) {
    if (debounce.isNegative) {
      throw ArgumentError.value(debounce, 'debounce', 'Must not be negative.');
    }
  }

  @override
  String get providerId => fluidAudioProviderId;

  /// Model window.
  final FluidEndOfUtteranceChunk chunk;

  /// Minimum interval between committed utterance ends.
  final Duration debounce;
}

/// Typed FluidAudio batch diarization configuration.
final class FluidDiarizationOptions implements SpeechProviderOptions {
  FluidDiarizationOptions({
    this.clusteringThreshold = 0.6,
    this.exactSpeakerCount,
  }) {
    _requireProbability(clusteringThreshold, 'clusteringThreshold');
    if (exactSpeakerCount != null && exactSpeakerCount! <= 0) {
      throw ArgumentError.value(
        exactSpeakerCount,
        'exactSpeakerCount',
        'Must be positive.',
      );
    }
  }

  @override
  String get providerId => fluidAudioProviderId;

  /// VBx clustering threshold.
  final double clusteringThreshold;

  /// Exact speaker count, overriding request minimum and maximum bounds.
  final int? exactSpeakerCount;
}

/// FluidAudio synthesis implementation.
enum FluidSynthesisEngine {
  /// Incremental PocketTTS generation.
  pocket,

  /// Kokoro English model.
  kokoroEnglish,

  /// Kokoro Mandarin model.
  kokoroMandarin,

  /// Kokoro Japanese model.
  kokoroJapanese,
}

/// Typed FluidAudio synthesis configuration.
final class FluidSynthesisOptions implements SpeechProviderOptions {
  FluidSynthesisOptions({
    this.engine = FluidSynthesisEngine.pocket,
    this.temperature = 0.7,
  }) {
    if (!temperature.isFinite || temperature < 0 || temperature > 2) {
      throw ArgumentError.value(
        temperature,
        'temperature',
        'Must be between 0 and 2.',
      );
    }
  }

  @override
  String get providerId => fluidAudioProviderId;

  /// Synthesis implementation and model variant.
  final FluidSynthesisEngine engine;

  /// PocketTTS sampling temperature.
  final double temperature;
}

void _requirePositive(double? value, String name) {
  if (value != null && (!value.isFinite || value <= 0)) {
    throw ArgumentError.value(value, name, 'Must be positive.');
  }
}

void _requireNonNegative(double? value, String name) {
  if (value != null && (!value.isFinite || value < 0)) {
    throw ArgumentError.value(value, name, 'Must not be negative.');
  }
}

void _requireProbability(double? value, String name) {
  if (value != null && (!value.isFinite || value < 0 || value > 1)) {
    throw ArgumentError.value(value, name, 'Must be between 0 and 1.');
  }
}
