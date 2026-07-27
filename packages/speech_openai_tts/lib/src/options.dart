import 'package:speech_core/speech_core.dart';

/// Audio payload requested from the OpenAI speech endpoint.
enum OpenAiTtsResponseFormat {
  /// Canonical RIFF/WAVE containing signed 16-bit PCM.
  wav('wav'),

  /// Headerless signed 16-bit little-endian PCM.
  pcm('pcm');

  const OpenAiTtsResponseFormat(this.wireName);

  /// OpenAI request value.
  final String wireName;
}

/// OpenAI-specific synthesis settings.
final class OpenAiTtsOptions implements SpeechProviderOptions {
  const OpenAiTtsOptions({
    this.responseFormat = OpenAiTtsResponseFormat.wav,
    this.instructions,
  });

  /// Response encoding requested from OpenAI.
  final OpenAiTtsResponseFormat responseFormat;

  /// Optional model-specific speaking instructions.
  final String? instructions;

  @override
  String get providerId => 'openai';
}

/// Endpoint, framing, and memory limits for OpenAI speech synthesis.
final class OpenAiTtsProviderConfig {
  OpenAiTtsProviderConfig({
    Uri? endpoint,
    this.defaultModelId = 'tts-1',
    this.defaultVoiceId = 'alloy',
    this.outputSampleRate = 24000,
    this.outputChannels = 1,
    this.frameDuration = const Duration(milliseconds: 20),
    this.maximumResponseBytes = 32 * 1024 * 1024,
  }) : endpoint =
           endpoint ?? Uri.parse('https://api.openai.com/v1/audio/speech') {
    if (defaultModelId.trim().isEmpty) {
      throw ArgumentError.value(
        defaultModelId,
        'defaultModelId',
        'Must not be empty.',
      );
    }
    if (defaultVoiceId.trim().isEmpty) {
      throw ArgumentError.value(
        defaultVoiceId,
        'defaultVoiceId',
        'Must not be empty.',
      );
    }
    if (outputSampleRate < 1 || outputChannels < 1) {
      throw ArgumentError('Output sample rate and channels must be positive.');
    }
    if (frameDuration <= Duration.zero) {
      throw ArgumentError.value(
        frameDuration,
        'frameDuration',
        'Must be positive.',
      );
    }
    if (maximumResponseBytes < 1) {
      throw ArgumentError.value(
        maximumResponseBytes,
        'maximumResponseBytes',
        'Must be positive.',
      );
    }
  }

  /// OpenAI speech endpoint.
  final Uri endpoint;

  /// Model used when a generic request does not select one.
  final String defaultModelId;

  /// Voice used when a generic request does not select one.
  final String defaultVoiceId;

  /// Expected OpenAI PCM output sample rate.
  final int outputSampleRate;

  /// Expected OpenAI PCM channel count.
  final int outputChannels;

  /// Frame size exposed by the resulting [AudioSource].
  final Duration frameDuration;

  /// Hard bound applied while reading the HTTP response.
  final int maximumResponseBytes;
}
