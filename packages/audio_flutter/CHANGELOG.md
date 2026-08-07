# Changelog

## 0.2.0

- Add `SystemAudioProcessSelector`, a pure expansion of a target app set over a
  `FlutterSystemAudio.listProcesses()` snapshot. Tapping Teams, Chrome, or
  Safari by their main process ID captured nothing, because those apps render
  audio in helper processes or in shared browser-engine processes under another
  bundle namespace. The prefix tables (browsers' external media processes,
  Electron helper suffixes, the Teams family) are public const and replaceable
  through the constructor.
- Add `FlutterMicrophonePermission` (`status()`/`request()`) and
  `AudioMicrophonePermissionStatus`. `FlutterAudioCaptureSource.prepare()` now
  fails a microphone capture with the typed `microphone_permission_denied`
  failure when access is denied or restricted, instead of starting an engine
  that delivers only zeroes. An undetermined status still reaches the system
  prompt, and a platform without a permission gate is never blocked.
- Add `FlutterSystemAudio.cleanupOrphanedCaptureDevices()`, which reclaims
  private capture devices leaked by a process that died mid-capture. Documented
  as an app-start call.
- Report `AudioDiscontinuityReason.sourceRestart` on frames whose native
  capture chain was rebuilt (an output-device switch, a helper process
  appearing). Every native gap used to arrive as `droppedFrames`; a restart
  that lost no frames now breaks continuity too, because the audio after it is
  not a continuation of the audio before it.
- Widen `FlutterAudioCaptureHealth` with `peakAmplitude`, `rms`,
  `nonZeroFramePercent`, `renderCycles`, and `firstAudioAtMillis`. A single
  `receivingAudio` bool could not tell a quiet room from a dead tap.
- Document the mic-delay recipe in the README: how to derive the start skew
  between two captures from their first `AudioFrame` timestamps and `clockId`s,
  for consumers such as mic-bleed dedup.

- Endorse `audio_flutter_linux` for `linux` and `audio_flutter_windows` for
  `windows`. Both are declared under `flutter.plugin.platforms` as
  `default_package`, so a host app that depends only on `audio_flutter` gets
  the platform implementation registered without naming it. The federated
  facade in `lib/` is unchanged: the new platforms arrive entirely through
  endorsement, not through new Dart API.
- Add `linux` and `windows` to the declared `platforms`. The package now
  advertises ios/linux/macos/windows. Capability is still per platform —
  system/process capture remains macOS-only.
- Add dependencies on `audio_flutter_linux: ^0.1.0` and
  `audio_flutter_windows: ^0.1.0`. Both packages are new because
  neither implementation has been published yet; this package cannot be
  re-released until they are live on pub.dev at a stable version and these
  constraints are widened to `^0.1.0`.
- Add `example/`, a minimal capture and device-listing app for
  windows/linux/macos. It is the only place the native halves of the federated
  plugin are compiled at all — the desktop CI jobs build it, and the Windows
  C++ plugin's first-ever compile happens there. Its macOS deployment target is
  14.0.
- Document in the README that Apple platforms still require the host app's
  `Info.plist` microphone usage description; the permission API added in this
  release governs the grant, not the declaration.
- Add `FlutterCaptureBackend`, the federated implementation of `audio_core`'s
  new `CaptureBackend` contract. Probes are single-use grants: a start must
  present the exact request/source pair that was probed, and the source is
  revalidated immediately before native allocation.
- Expose monotonic timing on prepared capture sessions: `timingQuality` and
  the `timing` mapping established by the first delivered frame, plus optional
  `logicalSourceId` and `timingQuality` overrides on the session config, so a
  host can carry a normalized source identity and timing provenance through to
  durable track manifests.

## 0.1.0

- Initial public release.
