import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

/// Recognition and VAD input used by the conversation controller.
///
/// [setRecognitionEnabled] gates recognition only. Implementations keep capture
/// and voice-activity detection active so speech can interrupt playback.
abstract interface class VoiceInput {
  /// Recognition events.
  Stream<SpeechRecognitionEvent> get transcripts;

  /// Voice-activity events that remain active while recognition is gated.
  Stream<VoiceActivityEvent> get voiceActivity;

  /// Starts capture after consumers have subscribed.
  Future<void> start({AudioCancellationToken? cancellationToken});

  /// Enables or gates speech recognition without stopping VAD capture.
  Future<void> setRecognitionEnabled(
    bool enabled, {
    AudioCancellationToken? cancellationToken,
  });

  /// Gracefully stops capture.
  Future<void> stop({AudioCancellationToken? cancellationToken});

  /// Releases input resources. Implementations must be idempotent.
  Future<void> close();
}

/// Plays a synthesized source without owning synthesis or capture.
abstract interface class VoiceSpeechOutput {
  /// Plays [source] to completion.
  Future<void> play(
    AudioSource source, {
    required AudioCancellationToken cancellationToken,
  });

  /// Immediately stops current playback and discards queued device audio.
  Future<void> interrupt();

  /// Releases playback resources. Implementations must be idempotent.
  Future<void> close();
}
