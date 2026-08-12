# Changelog

## 0.3.0

- **Wire format: upgrade Dart and native together.** The regenerated pigeon
  messages (`Messages.g.dart` / `Messages.g.swift`) insert
  `CaptureRequestMessage.bundleIds` at positional index 6, shifting
  `inputDeviceId` and `rawRecordingPath` up by one. A 0.2.0 Swift pod against
  0.3.0 Dart (or vice versa) mis-decodes capture requests silently.
- **New terminal failure modes for microphone capture.** A microphone tap
  that stays silent past the supervision budget now fails the session with
  `MicrophoneCaptureDead` (only after a real rebuild was attempted) or
  `MicrophoneInputFormatUnavailable` (five consecutive windows with no usable
  input format); `MicrophoneEngineRestartFailed` reports a failed engine
  restart. Previously a dead microphone recorded silence forever. These
  three arrive as `failed` (fatal); every other new code below is an
  `interrupted` disclosure, not a failure.
- Replace the one-shot capture watchdog with a windowed supervision loop.
  An armed system tap whose target app has not rendered audio yet reports
  `SystemCaptureAwaitingAppAudio` (once per session) instead of dying;
  `SystemCaptureDead` is reserved for a running aggregate device whose IO
  proc never fires, or two consecutive advancing windows with render cycles
  but no converted audio.
- Fix a 2× playback-speed corruption: IO-proc buffers are now wrapped in the
  tap layout re-rated to the aggregate's nominal sample rate
  (`formatAtDeviceRate`) instead of the tap's advertised format, which lies
  when the clock device renegotiates (Bluetooth A2DP↔HFP). A nominal-rate
  listener on the aggregate emits `CaptureSampleRateChanged` and rebuilds the
  chain on renegotiation.
- Microphone capture reads its input format once at start, rebuilds the
  converter from that same read, and registers its configuration-change
  observer before `engine.start()`. Recovery emits
  `MicrophoneInputFormatChanged` after a successful tap reinstall;
  `MicrophoneTapSilent` and `MicrophoneAwaitingInputFormat` disclose
  transient states; a bounded skip budget escalates to
  `MicrophoneInputFormatUnavailable`, and `MicrophoneCaptureDead` requires a
  real rebuild attempt first.
- Close the raw source-native recording when the delivered format changes
  mid-capture (`MicrophoneRecordingFormatChanged` /
  `SystemRecordingFormatChanged`): one WAV file cannot hold two formats.
- On macOS 26+, tap descriptions target `CATapDescription.bundleIDs` with
  process restoration enabled; older systems resolve bundle IDs to process
  objects at tap-build time.
- The unclocked-aggregate fallback no longer reports a `clockDeviceUid` it
  does not have.

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
