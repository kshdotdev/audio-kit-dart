import 'failure.dart';
import 'transcript.dart';
import 'validation.dart';

/// Base type for typed streaming recognition events.
sealed class SpeechRecognitionEvent {
  SpeechRecognitionEvent({required this.at}) {
    requireNonNegativeDuration(at, 'at');
  }

  /// Offset in the input session at which this event was observed.
  final Duration at;
}

/// Recognition observed the beginning of speech.
final class RecognitionSpeechStarted extends SpeechRecognitionEvent {
  RecognitionSpeechStarted({required super.at});
}

/// A replaceable, non-final recognition hypothesis.
final class RecognitionPartial extends SpeechRecognitionEvent {
  RecognitionPartial({
    required this.transcript,
    required this.revision,
    required super.at,
  }) {
    if (revision < 0) {
      throw ArgumentError.value(revision, 'revision', 'Must not be negative.');
    }
  }

  /// Current hypothesis.
  final SpeechTranscript transcript;

  /// Monotonically increasing hypothesis revision within the session.
  final int revision;
}

/// A committed recognition segment.
final class RecognitionFinal extends SpeechRecognitionEvent {
  RecognitionFinal({
    required this.transcript,
    required this.segmentId,
    required super.at,
  }) {
    requireNonEmpty(segmentId, 'segmentId');
  }

  /// Final transcript.
  final SpeechTranscript transcript;

  /// Stable segment ID within the session.
  final String segmentId;
}

/// Recognition observed the end of speech.
final class RecognitionSpeechEnded extends SpeechRecognitionEvent {
  RecognitionSpeechEnded({required super.at});
}

/// Recognition failed. The session may also report a terminal audio status.
final class RecognitionFailed extends SpeechRecognitionEvent {
  RecognitionFailed({required this.failure, required super.at});

  /// Safe, provider-neutral failure.
  final SpeechFailure failure;
}

/// Base type for voice-activity events.
sealed class VoiceActivityEvent {
  VoiceActivityEvent({required this.at}) {
    requireNonNegativeDuration(at, 'at');
  }

  /// Offset in the input session.
  final Duration at;
}

/// Voice activity entered the speaking state.
final class VoiceActivityStarted extends VoiceActivityEvent {
  VoiceActivityStarted({required this.probability, required super.at}) {
    requireProbability(probability, 'probability');
  }

  /// Speech probability in the inclusive range 0–1.
  final double probability;
}

/// A non-transitioning activity estimate.
final class VoiceActivityProbability extends VoiceActivityEvent {
  VoiceActivityProbability({
    required this.probability,
    required this.isSpeech,
    required super.at,
  }) {
    requireProbability(probability, 'probability');
  }

  /// Speech probability in the inclusive range 0–1.
  final double probability;

  /// Current thresholded activity state.
  final bool isSpeech;
}

/// Voice activity left the speaking state.
final class VoiceActivityEnded extends VoiceActivityEvent {
  VoiceActivityEnded({required this.probability, required super.at}) {
    requireProbability(probability, 'probability');
  }

  /// Speech probability in the inclusive range 0–1.
  final double probability;
}

/// Provider estimate that the current utterance has ended.
final class EndOfUtteranceEvent {
  EndOfUtteranceEvent({
    required this.probability,
    required this.at,
    required this.isFinal,
  }) {
    requireProbability(probability, 'probability');
    requireNonNegativeDuration(at, 'at');
  }

  /// End-of-utterance probability in the inclusive range 0–1.
  final double probability;

  /// Offset in the input session.
  final Duration at;

  /// Whether the provider committed the end-of-utterance decision.
  final bool isFinal;
}

/// Updated speaker segmentation for an audio interval.
final class DiarizationEvent {
  DiarizationEvent({
    required Iterable<SpeakerSegment> segments,
    required this.isFinal,
  }) : segments = List<SpeakerSegment>.unmodifiable(segments);

  /// Speaker segments ordered by start time.
  final List<SpeakerSegment> segments;

  /// Whether these segments will no longer be revised.
  final bool isFinal;
}
