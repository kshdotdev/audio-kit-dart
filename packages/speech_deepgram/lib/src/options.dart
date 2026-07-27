import 'package:speech_core/speech_core.dart';

/// Diarization model supported by Deepgram's live endpoint.
enum DeepgramDiarizationModel {
  /// Provider-selected current model.
  latest('latest'),

  /// Version 1 streaming diarization.
  v1('v1');

  const DeepgramDiarizationModel(this.wireName);

  /// Deepgram query value.
  final String wireName;
}

/// Deepgram-specific settings that do not belong in provider-neutral core.
final class DeepgramStreamingOptions implements SpeechProviderOptions {
  DeepgramStreamingOptions({
    this.interimResults = true,
    this.smartFormat = true,
    this.diarizationModel,
    this.voiceActivityEvents = true,
    this.endpointing = const Duration(milliseconds: 300),
    this.utteranceEnd,
    this.profanityFilter = false,
    this.numerals = false,
    this.detectLanguage = false,
    this.tag,
  }) {
    if (endpointing.isNegative) {
      throw ArgumentError.value(
        endpointing,
        'endpointing',
        'Must not be negative.',
      );
    }
    if (utteranceEnd?.isNegative ?? false) {
      throw ArgumentError.value(
        utteranceEnd,
        'utteranceEnd',
        'Must not be negative.',
      );
    }
    if (utteranceEnd != null && !interimResults) {
      throw ArgumentError.value(
        utteranceEnd,
        'utteranceEnd',
        'Utterance-end events require interim results.',
      );
    }
  }

  /// Whether replaceable partial hypotheses should be emitted.
  final bool interimResults;

  /// Whether Deepgram should apply its smart formatting pass.
  final bool smartFormat;

  /// Streaming diarization model, or `null` to disable speaker labels.
  final DeepgramDiarizationModel? diarizationModel;

  /// Whether explicit speech-start events should be requested.
  final bool voiceActivityEvents;

  /// Silence duration used by Deepgram endpoint detection.
  final Duration endpointing;

  /// Optional delay before an explicit utterance-end event is requested.
  final Duration? utteranceEnd;

  /// Whether profanity filtering is enabled.
  final bool profanityFilter;

  /// Whether written numbers are requested.
  final bool numerals;

  /// Whether Deepgram should detect the input language.
  final bool detectLanguage;

  /// Optional application tag included in Deepgram request metadata.
  final String? tag;

  @override
  String get providerId => 'deepgram';
}

/// Connection and buffering configuration for the Deepgram adapter.
final class DeepgramProviderConfig {
  DeepgramProviderConfig({
    Uri? endpoint,
    this.defaultModelId = 'nova-3',
    this.maximumQueuedAudioBytes = 512 * 1024,
    this.pingInterval = const Duration(seconds: 10),
    this.closeTimeout = const Duration(seconds: 5),
  }) : endpoint = endpoint ?? Uri.parse('wss://api.deepgram.com/v1/listen') {
    if (maximumQueuedAudioBytes < 1) {
      throw ArgumentError.value(
        maximumQueuedAudioBytes,
        'maximumQueuedAudioBytes',
        'Must be positive.',
      );
    }
    if (defaultModelId.trim().isEmpty) {
      throw ArgumentError.value(
        defaultModelId,
        'defaultModelId',
        'Must not be empty.',
      );
    }
    if (pingInterval <= Duration.zero) {
      throw ArgumentError.value(
        pingInterval,
        'pingInterval',
        'Must be positive.',
      );
    }
    if (closeTimeout <= Duration.zero) {
      throw ArgumentError.value(
        closeTimeout,
        'closeTimeout',
        'Must be positive.',
      );
    }
  }

  /// Deepgram websocket endpoint.
  final Uri endpoint;

  /// Model used when the generic request does not select one.
  final String defaultModelId;

  /// Hard bound for audio accepted but not yet drained into the transport's
  /// socket write path.
  final int maximumQueuedAudioBytes;

  /// Websocket ping cadence for the built-in transport.
  final Duration pingInterval;

  /// Maximum time the built-in transport waits for a graceful remote close.
  final Duration closeTimeout;
}
