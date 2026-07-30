import 'package:audio_core/audio_core.dart';

import 'events.dart';
import 'provider.dart';
import 'requests.dart';
import 'transcript.dart';
import 'validation.dart';

/// A streaming STT session that accepts provider-neutral audio frames.
abstract interface class StreamingSpeechToTextSession
    implements AudioSinkSession {
  /// Typed recognition results.
  Stream<SpeechRecognitionEvent> get results;
}

/// Provider capable of streaming speech recognition.
abstract interface class StreamingSpeechToTextProvider
    implements SpeechProvider {
  /// Prepares a session. Consumers may subscribe before writing the first frame.
  Future<StreamingSpeechToTextSession> prepareStreamingRecognition(
    StreamingRecognitionRequest request,
  );
}

/// Provider capable of batch speech recognition.
abstract interface class BatchSpeechToTextProvider implements SpeechProvider {
  /// Consumes [BatchRecognitionRequest.audio] and returns a committed result.
  Future<BatchRecognitionResult> transcribe(BatchRecognitionRequest request);
}

/// A streaming voice-activity session.
abstract interface class VoiceActivityDetectionSession
    implements AudioSinkSession {
  /// Typed voice-activity results.
  Stream<VoiceActivityEvent> get events;
}

/// Provider capable of streaming voice-activity detection.
abstract interface class VoiceActivityDetectionProvider
    implements SpeechProvider {
  /// Prepares a session. Consumers may subscribe before writing the first frame.
  Future<VoiceActivityDetectionSession> prepareVoiceActivityDetection(
    VoiceActivityDetectionRequest request,
  );
}

/// A streaming end-of-utterance session.
abstract interface class EndOfUtteranceSession implements AudioSinkSession {
  /// Typed end-of-utterance estimates.
  Stream<EndOfUtteranceEvent> get events;
}

/// Provider capable of streaming end-of-utterance detection.
abstract interface class EndOfUtteranceProvider implements SpeechProvider {
  /// Prepares a session. Consumers may subscribe before writing the first frame.
  Future<EndOfUtteranceSession> prepareEndOfUtterance(
    EndOfUtteranceRequest request,
  );
}

/// A streaming speaker-diarization session.
///
/// **RESERVED — no adapter implements this yet.** It is a declared shape, not
/// a supported capability: nothing in this repository returns a
/// [DiarizationSession], and `SpeechCapability.diarization` on a provider today
/// means [BatchDiarizationProvider] only. Callers must not treat the capability
/// flag as a promise that [DiarizationProvider.prepareDiarization] exists.
///
/// The contract may change before the first implementation lands. Streaming
/// diarization has to answer questions batch diarization never faces — whether
/// a speaker label may be revised after it is emitted, how far back a
/// re-clustering pass may reach, what a partial segment means at the live edge
/// — and those answers belong to the adapter that first has to give them.
/// Implementing against this shape now means implementing against a guess.
abstract interface class DiarizationSession implements AudioSinkSession {
  /// Typed speaker segmentation updates.
  Stream<DiarizationEvent> get events;
}

/// Provider capable of streaming speaker diarization.
///
/// **RESERVED — no adapter implements this yet.** See [DiarizationSession] for
/// what that means and why the contract may still change. Use
/// [BatchDiarizationProvider] for diarization that works today.
abstract interface class DiarizationProvider implements SpeechProvider {
  /// Prepares a session. Consumers may subscribe before writing the first frame.
  Future<DiarizationSession> prepareDiarization(DiarizationRequest request);
}

/// Request for batch speaker diarization.
final class BatchDiarizationRequest {
  BatchDiarizationRequest({
    required this.audio,
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

  /// Audio to consume.
  final AudioSource audio;

  /// Optional lower speaker-count bound.
  final int? minimumSpeakers;

  /// Optional upper speaker-count bound.
  final int? maximumSpeakers;

  /// Optional cooperative cancellation signal.
  final AudioCancellationToken? cancellation;

  /// Typed advanced options owned by an adapter package.
  final SpeechProviderOptions? providerOptions;
}

/// Result from batch speaker diarization.
final class BatchDiarizationResult {
  BatchDiarizationResult({required Iterable<SpeakerSegment> segments})
    : segments = List<SpeakerSegment>.unmodifiable(segments);

  /// Speaker segments ordered by start time.
  final List<SpeakerSegment> segments;
}

/// Provider capable of batch speaker diarization.
abstract interface class BatchDiarizationProvider implements SpeechProvider {
  /// Consumes [BatchDiarizationRequest.audio] and returns committed segments.
  Future<BatchDiarizationResult> diarize(BatchDiarizationRequest request);
}

/// Text-to-speech provider whose output is a reusable [AudioSource].
abstract interface class TextToSpeechProvider implements SpeechProvider {
  /// Creates a cold source. Synthesis begins through normal source lifecycle.
  AudioSource synthesize(SpeechSynthesisRequest request);
}
