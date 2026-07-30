# Changelog

## 0.1.0-dev

- Initial package: Linux capture and PCM playback for `audio_flutter` over the
  PulseAudio/PipeWire command-line tools, with no native code.
- Capture spawns `parecord` and falls back to `pw-record`; playback spawns
  `paplay` and falls back to `pw-play`.
- Source targeting, monitor resolution from the default sink, and input/monitor
  enumeration via `pactl`.
- Bounded frame ring honouring `maxBufferedDuration` and every
  `PlatformCaptureOverflowPolicy`, drained by `readCaptureFrames`.
- Stall watchdog reporting `SystemCaptureDead`, plus process-exit failures
  carrying a stderr excerpt.
- `rawRecordingPath` support through a streaming WAV writer.
