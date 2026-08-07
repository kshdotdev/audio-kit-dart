# Changelog

## 0.2.0

- Add opt-in full-duplex conversation mode. `VoiceDuplexMode`,
  `VoiceEchoCancellationFallback`, and `VoiceDuplexConfig` select between the
  default half-duplex flow and a full-duplex flow in which the user can speak
  over synthesized playback. Half duplex remains the default and its behavior is
  unchanged: pass nothing and nothing moves.
- `VoiceConversationController` takes a `duplex` policy. In full duplex it never
  calls `VoiceInput.setRecognitionEnabled` — the microphone is expected to be
  echo-cancelled upstream, so recognition is never torn down and the onset of an
  interrupting utterance is no longer lost — and voice activity alone no longer
  interrupts playback. A committed final transcript still starts a new turn in
  both modes, and `interruptTurn()` still works in both.
- Add `VoiceDuplexConfig.interruptAfterSustainedSpeech`, an opt-in dwell after
  which sustained user speech interrupts full-duplex playback early. It stacks
  on the detector's own hysteresis rather than replacing it. Default `null`.
- Add `VoiceConversationSnapshot.duplexMode`, the mode actually in effect.
  Resolution happens at construction, so the first snapshot a listener sees
  already reports an honest mode.
- Full duplex requested without echo cancellation resolves to half duplex by
  default (`VoiceDuplexConfig.isDegraded`), on the principle that the degraded
  mode must never be worse than the no-AEC baseline: an open, uncancelled
  microphone makes the recognizer transcribe the assistant. Running full duplex
  anyway requires explicitly passing
  `VoiceEchoCancellationFallback.acceptEchoRisk`.
- `voice_core` still has no dependency on `audio_aec` and no knowledge of echo
  cancellation. It is told whether the microphone is clean; the composition
  lives in `voice_flutter`.

## 0.1.0

- Initial public release.
