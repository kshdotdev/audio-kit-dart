# Changelog

## 0.1.0

- Initial package: Linux capture and PCM playback for `audio_flutter` over the
  PulseAudio/PipeWire command-line tools, with no native code.
- Capture spawns `parecord` and falls back to `pw-record`; playback spawns
  `paplay` and falls back to `pw-play`.
- Source targeting, monitor resolution from the default sink, and input/monitor
  enumeration via `pactl`.
- Exact active render-stream capture through PulseAudio/PipeWire-Pulse sink
  inputs and `parecord --monitor-stream`, with source/PID revalidation and no
  broad `pw-record` fallback.
- Bounded frame ring honouring `maxBufferedDuration` and every
  `PlatformCaptureOverflowPolicy`, drained by `readCaptureFrames`.
- Stall watchdog reporting `SystemCaptureDead`, plus process-exit failures
  carrying a stderr excerpt.
- `rawRecordingPath` support through a streaming WAV writer.
