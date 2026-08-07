# Changelog

## 0.2.0

- Implement `microphonePermissionStatus()` and `requestMicrophonePermission()`
  over `AVCaptureDevice.authorizationStatus(for: .audio)` and `requestAccess`.
  The request prompts only from `notDetermined`; a denied or restricted status
  is reported unchanged rather than re-prompting, which the system would not
  show anyway.
- Watch `kAudioHardwarePropertyDefaultOutputDevice` while a system capture is
  running. The tap aggregate is clocked from whichever output device was
  default when it was built, so switching output (speakers to AirPods, HDMI
  unplugged) left it clocked by a device the user no longer routes to — or one
  that vanished, which stops the IO proc silently. The listener rebuilds the
  chain against the new default and reports the break as
  `AudioDiscontinuityReason.sourceRestart` on the next frame. Tap-only
  aggregates (no clock device) and notifications that resolve to the same
  device do not rebuild.
- Carry a discontinuity reason on native frames, so a rebuild is no longer
  indistinguishable from a mailbox overflow.
- Give the private aggregate device a recognizable UID prefix
  (`audio-flutter.tap.`) instead of a bare UUID; the human-readable device name
  is unchanged. Add `cleanupOrphanedAggregateDevices()`, which destroys devices
  carrying that prefix that no live session in this process owns — the ones a
  `kill -9` or a crash leaves in the device tree.
- Widen the capture statistics behind the health stream: peak amplitude, RMS,
  non-zero-buffer percentage, hardware render cycles, and time to first audio,
  for both microphone and system capture. The emission cadence is unchanged —
  these ride the health events that already existed.

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
- Lower the Swift package platform floor from macOS 14 to macOS 12. The plugin
  shell, microphone capture, and playback run on macOS 12; process-tap system
  audio stays runtime-gated to macOS 14.4 behind `@available` guards, so host
  applications can launch on macOS 12/13 and see system capture reported as
  unsupported there instead of failing to link.
- Add a Swift test target covering the darwin support layer.

## 0.1.0

- Initial public release.
