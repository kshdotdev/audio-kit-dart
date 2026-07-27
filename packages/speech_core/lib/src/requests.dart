import 'package:audio_core/audio_core.dart';

import 'validation.dart';

/// Marker for typed provider-specific options.
///
/// Core requests remain provider-neutral while adapters may expose an options
/// implementation without using dynamic maps or leaking SDK types.
abstract interface class SpeechProviderOptions {
  /// Stable provider ID understood by these options.
  String get providerId;
}

/// Common provider-neutral recognition configuration.
final class SpeechRecognitionOptions {
  SpeechRecognitionOptions({
    this.modelId,
    this.languageTag,
    this.punctuate = true,
    this.wordTimings = true,
    this.maxAlternatives = 1,
    Iterable<String> vocabulary = const <String>[],
    this.providerOptions,
  }) : vocabulary = List<String>.unmodifiable(vocabulary) {
    if (maxAlternatives < 1) {
      throw ArgumentError.value(
        maxAlternatives,
        'maxAlternatives',
        'Must be positive.',
      );
    }
  }

  /// Provider-scoped model ID, or `null` for the provider default.
  final String? modelId;

  /// Requested BCP-47 language tag, or `null` for automatic/default behavior.
  final String? languageTag;

  /// Whether punctuation should be added when supported.
  final bool punctuate;

  /// Whether word timings should be returned when supported.
  final bool wordTimings;

  /// Maximum number of transcript alternatives.
  final int maxAlternatives;

  /// Domain vocabulary or phrase hints.
  final List<String> vocabulary;

  /// Typed advanced options owned by an adapter package.
  final SpeechProviderOptions? providerOptions;
}

/// Configuration for a streaming STT session.
final class StreamingRecognitionRequest {
  StreamingRecognitionRequest({
    required this.inputFormat,
    SpeechRecognitionOptions? options,
    this.cancellation,
  }) : options = options ?? SpeechRecognitionOptions();

  /// Fixed input format accepted by the session.
  final AudioFormat inputFormat;

  /// Recognition behavior.
  final SpeechRecognitionOptions options;

  /// Optional cooperative cancellation signal.
  final AudioCancellationToken? cancellation;
}

/// Configuration for batch speech recognition.
final class BatchRecognitionRequest {
  BatchRecognitionRequest({
    required this.audio,
    SpeechRecognitionOptions? options,
    this.cancellation,
    this.onProgress,
  }) : options = options ?? SpeechRecognitionOptions();

  /// Audio to consume. The provider never owns capture hardware.
  final AudioSource audio;

  /// Recognition behavior.
  final SpeechRecognitionOptions options;

  /// Optional cooperative cancellation signal.
  final AudioCancellationToken? cancellation;

  /// Optional progress callback in the inclusive range 0–1.
  final void Function(double progress)? onProgress;
}

/// Result from a batch recognition operation.
final class BatchRecognitionResult {
  BatchRecognitionResult({
    required this.text,
    Iterable<BatchRecognitionSegment> segments =
        const <BatchRecognitionSegment>[],
    this.languageTag,
  }) : segments = List<BatchRecognitionSegment>.unmodifiable(segments);

  /// Complete recognized text.
  final String text;

  /// Timed transcript segments.
  final List<BatchRecognitionSegment> segments;

  /// Detected or requested BCP-47 language tag.
  final String? languageTag;
}

/// One committed segment in a batch recognition result.
final class BatchRecognitionSegment {
  BatchRecognitionSegment({
    required this.text,
    required this.start,
    required this.end,
    this.speakerId,
  }) {
    requireNonNegativeDuration(start, 'start');
    if (end < start) {
      throw ArgumentError.value(end, 'end', 'Must not precede start.');
    }
    requireOptionalNonEmpty(speakerId, 'speakerId');
  }

  /// Segment text.
  final String text;

  /// Inclusive start offset.
  final Duration start;

  /// Exclusive end offset.
  final Duration end;

  /// Provider-neutral speaker label.
  final String? speakerId;
}

/// Configuration for a streaming VAD session.
final class VoiceActivityDetectionRequest {
  VoiceActivityDetectionRequest({
    required this.inputFormat,
    this.startThreshold = 0.6,
    this.endThreshold = 0.4,
    this.minimumSpeech = const Duration(milliseconds: 100),
    this.minimumSilence = const Duration(milliseconds: 300),
    this.cancellation,
    this.providerOptions,
  }) {
    requireProbability(startThreshold, 'startThreshold');
    requireProbability(endThreshold, 'endThreshold');
    requirePositiveDuration(minimumSpeech, 'minimumSpeech');
    requireNonNegativeDuration(minimumSilence, 'minimumSilence');
  }

  /// Fixed input format accepted by the session.
  final AudioFormat inputFormat;

  /// Probability required to enter speech.
  final double startThreshold;

  /// Probability below which speech may end.
  final double endThreshold;

  /// Required speech duration before a start event.
  final Duration minimumSpeech;

  /// Required silence duration before an end event.
  final Duration minimumSilence;

  /// Optional cooperative cancellation signal.
  final AudioCancellationToken? cancellation;

  /// Typed advanced options owned by an adapter package.
  final SpeechProviderOptions? providerOptions;
}

/// Configuration for a streaming end-of-utterance session.
final class EndOfUtteranceRequest {
  EndOfUtteranceRequest({
    required this.inputFormat,
    this.threshold = 0.8,
    this.cancellation,
    this.providerOptions,
  }) {
    requireProbability(threshold, 'threshold');
  }

  /// Fixed input format accepted by the session.
  final AudioFormat inputFormat;

  /// Probability required for a committed decision.
  final double threshold;

  /// Optional cooperative cancellation signal.
  final AudioCancellationToken? cancellation;

  /// Typed advanced options owned by an adapter package.
  final SpeechProviderOptions? providerOptions;
}

/// Configuration for a streaming diarization session.
final class DiarizationRequest {
  DiarizationRequest({
    required this.inputFormat,
    this.minimumSpeakers,
    this.maximumSpeakers,
    this.cancellation,
    this.providerOptions,
  }) {
    validateSpeakerBounds(
      minimumSpeakers: minimumSpeakers,
      maximumSpeakers: maximumSpeakers,
    );
  }

  /// Fixed input format accepted by the session.
  final AudioFormat inputFormat;

  /// Optional lower speaker-count bound.
  final int? minimumSpeakers;

  /// Optional upper speaker-count bound.
  final int? maximumSpeakers;

  /// Optional cooperative cancellation signal.
  final AudioCancellationToken? cancellation;

  /// Typed advanced options owned by an adapter package.
  final SpeechProviderOptions? providerOptions;
}

/// Provider-neutral TTS generation parameters.
final class SpeechSynthesisRequest {
  SpeechSynthesisRequest({
    required this.text,
    this.modelId,
    this.voiceId,
    this.languageTag,
    this.rate = 1,
    this.pitch = 0,
    this.cancellation,
    this.providerOptions,
  }) {
    requireNonEmpty(text, 'text');
    if (!rate.isFinite || rate <= 0) {
      throw ArgumentError.value(rate, 'rate', 'Must be finite and positive.');
    }
    if (!pitch.isFinite || pitch < -1 || pitch > 1) {
      throw ArgumentError.value(pitch, 'pitch', 'Must be between -1 and 1.');
    }
  }

  /// Text to synthesize.
  final String text;

  /// Provider-scoped model ID, or `null` for the provider default.
  final String? modelId;

  /// Provider-scoped voice ID, or `null` for the provider default.
  final String? voiceId;

  /// Requested BCP-47 language tag.
  final String? languageTag;

  /// Relative speaking rate, where 1 is normal.
  final double rate;

  /// Relative pitch adjustment in the inclusive range -1–1.
  final double pitch;

  /// Optional cooperative cancellation signal.
  final AudioCancellationToken? cancellation;

  /// Typed advanced options owned by an adapter package.
  final SpeechProviderOptions? providerOptions;
}
