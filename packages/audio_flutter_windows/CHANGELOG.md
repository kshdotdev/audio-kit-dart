# Changelog

## 0.1.0

- Initial package: Windows capture and PCM playback for `audio_flutter` over
  WASAPI, with cross-compiler native validation and a full MSVC CI build.
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
- Process-tree isolation through Windows application-loopback activation on OS
  build 20348+, including multi-root QPC alignment and render-session discovery.
- Windows 10 22H2 keeps explicit system-mix capture while reporting process
  isolation unavailable instead of silently broadening it.
- `rawRecordingPath` is rejected rather than silently ignored.
