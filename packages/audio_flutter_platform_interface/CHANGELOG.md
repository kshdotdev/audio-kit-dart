# Changelog

## Unreleased

- Add `microphonePermissionStatus()` and `requestMicrophonePermission()` to
  `AudioFlutterPlatform`, returning the new
  `PlatformMicrophonePermissionStatus`. Both carry `UnimplementedError` default
  bodies, so a platform package written against 0.1.0 keeps compiling and
  callers can distinguish "no permission gate on this platform" from "denied".
- Add `cleanupOrphanedCaptureDevices()`, which destroys private capture devices
  the plugin leaked in an earlier run and reports how many were reclaimed. Same
  `UnimplementedError` default.
- Add `PlatformAudioFrame.discontinuityReason` (nullable
  `PlatformAudioDiscontinuityReason`). Native gaps used to travel as a bare
  `droppedFramesBefore` count, which app-facing code could only ever map to
  `droppedFrames`; a rebuilt capture chain can now report itself as
  `sourceRestart`, including when it dropped no frames at all.
- Add nullable `peakAmplitude`, `rms`, `nonZeroFramePercent`, `renderCycles`,
  and `firstAudioAtMillis` to `PlatformAudioSessionEvent`. They separate a
  silent room from a dead tap, and a device that never ran from one that runs
  and delivers zeroes.

## 0.1.0

- Initial public release.
