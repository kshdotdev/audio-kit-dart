# Changelog

## Unreleased

- Clock the macOS system-audio tap aggregate off the current default output
  device (`kAudioAggregateDeviceMainSubDeviceKey` +
  `kAudioAggregateDeviceClockDeviceKey`), which fixes hardware-dependent silent
  captures where a tap-only aggregate was never clocked. Falls back to the
  previous tap-only aggregate when there is no default output device or the HAL
  rejects the clocked composition.
- Hold a refcounted `ProcessInfo.beginActivity` assertion (macOS only) while any
  microphone or system-audio capture session is running, so an unfocused app no
  longer buffers and bursts capture callbacks under App Nap.
- Document the system-audio permission preflight as advisory: the macOS grant is
  enforced at delivery, so it can report success for a tap that will deliver
  only silence. Capture health remains the authoritative signal.

## 0.1.0

- Initial public release.
