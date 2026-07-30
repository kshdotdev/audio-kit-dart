/// Minimum-audio policy every batch recognition provider enforces.
///
/// Recognition models are trained on windows, not on arbitrarily short
/// fragments: a sub-second buffer is decoded as garbage, as an empty string, or
/// as a native error whose shape differs per provider. The guard belongs at the
/// provider boundary rather than in each app, and it is a typed failure rather
/// than a silent drop — an empty transcript is indistinguishable from "the user
/// said nothing", which is exactly the diagnosis a push-to-talk trigger firing
/// too fast needs to rule out.
abstract final class SpeechAudioGuards {
  /// Shortest audio a batch recognizer accepts.
  ///
  /// One second is 16,000 samples at the 16 kHz every adapter converts to, the
  /// window Parakeet requires; providers below it refuse the request with
  /// [audioTooShortCode] instead of transcribing.
  static const Duration minimumRecognitionDuration = Duration(seconds: 1);

  /// `SpeechFailure.code` raised for audio shorter than
  /// [minimumRecognitionDuration].
  ///
  /// Shared across adapters so a caller can recognize the condition without
  /// knowing which provider is behind the request; the failure still carries
  /// its own `providerId`.
  static const String audioTooShortCode = 'speech_audio_too_short';
}
