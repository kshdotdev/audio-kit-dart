# Changelog

## Unreleased

- Initial package: Windows capture and PCM playback for `audio_flutter` over
  WASAPI. **The native half has not been compiled** — see the README.
- System audio through shared-mode loopback on a render endpoint; microphone
  through the same client on an `eCapture` endpoint.
- Endpoint mix format is read rather than assumed, decoding IEEE float32 and
  8/16/24/32-bit integer PCM, down-mixing to mono and resampling with a
  phase-continuous linear interpolator.
- Capture threads run on the MMCSS "Pro Audio" task and poll at half the
  endpoint buffer in 5 ms slices, so stop latency stays bounded.
- Bounded frame ring per session honouring `maxBufferedDuration` and every
  `PlatformCaptureOverflowPolicy`, drained by `readCaptureFrames`; audio is
  pulled, so only lifecycle events cross the event channel.
- Stall watchdog reporting `CaptureStalled` when an initialised capture never
  delivers audio.
- Endpoint enumeration for both capture inputs and render targets, plus
  playback through `IAudioRenderClient`.
- `processIds` and `rawRecordingPath` are rejected rather than silently ignored.
