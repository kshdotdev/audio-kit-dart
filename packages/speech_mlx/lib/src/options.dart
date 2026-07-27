import 'package:speech_core/speech_core.dart';

/// Stable provider identifier used by the MLX adapter.
const String mlxSpeechProviderId = 'mlx';

/// MLX decoding controls without leaking MLX package types into `speech_core`.
final class MlxRecognitionOptions implements SpeechProviderOptions {
  const MlxRecognitionOptions({
    this.maxTokens = 8192,
    this.temperature = 0,
    this.topP = 0.95,
    this.topK = 0,
    this.repetitionPenalty = 1,
    this.repetitionContextSize = 32,
  });

  @override
  String get providerId => mlxSpeechProviderId;

  final int maxTokens;
  final double temperature;
  final double topP;
  final int topK;
  final double repetitionPenalty;
  final int repetitionContextSize;
}

/// MLX synthesis controls without leaking `mlx_audio` parameter types.
final class MlxSynthesisOptions implements SpeechProviderOptions {
  const MlxSynthesisOptions({
    this.temperature = 0.7,
    this.maxTokens,
    this.seed,
  });

  @override
  String get providerId => mlxSpeechProviderId;

  /// Noise scale used by PocketTTS generation.
  final double temperature;

  /// Optional maximum number of generated codec frames per text chunk.
  final int? maxTokens;

  /// Optional deterministic MLX random seed.
  final int? seed;
}
