# Changelog

## Unreleased

- Add `VoiceFarEndTap`, the acoustic-echo-cancellation far-end reference for a
  voice conversation. It is one long-lived `AudioSource` fed by a succession of
  short-lived `AudioSink` sessions — one per `GraphVoiceSpeechOutput.play` call
  — which bridges the lifetime mismatch between per-sentence playback graphs and
  the single capture-long session an `AecMicFilter` binds. Attached beside device
  playback, the router fans each synthesized frame to the speakers and the
  canceller from one dispatch, in one order. A reference whose format does not
  match capture is rejected at `prepare` rather than silently tapped.
- Add `VoiceFullDuplexSetup.compose`, which builds the echo canceller, wires the
  tap, and returns the resolved `VoiceDuplexConfig` to hand to
  `VoiceConversationController`. This is where the AEC composition lives:
  `voice_core` stays pure orchestration with no `audio_aec` dependency, and the
  mechanism is `audio_core` sources plus `audio_kit_graph` fan-out, which
  `voice_flutter` already depends on.
- Add `VoiceEchoCancellationOutcome`. `AecUnavailable` is caught exactly once, in
  `compose`, and turned into a resolved policy: by default the session degrades
  to half duplex and returns the raw microphone untouched, so the degraded path
  is the ordinary half-duplex path rather than a passthrough wrapper around it.
  `VoiceEchoCancellationFallback.acceptEchoRisk` keeps full duplex against an
  uncancelled microphone. The structured `AecUnavailable` — including every
  library path the loader tried — is surfaced on the setup.
- One composition drives one capture session: `AecMicFilter` binds a single
  stateful native engine and rejects a second `prepare`, so a `GraphVoiceInput`
  over the composed microphone cannot be restarted after `stop()`.
- Add a dependency on `audio_aec`. Half-duplex behavior is unchanged.

## 0.1.0

- Initial public release.
