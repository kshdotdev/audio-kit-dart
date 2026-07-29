# Changelog

## Unreleased

- Initial implementation of `audio_aec`: acoustic echo cancellation for Audio
  Kit streams over WebRTC AEC3.
- Add `AecBindings`, the six-symbol C ABI (`aec_create`, `aec_process_reverse`,
  `aec_process_capture`, `aec_get_metrics`, `aec_destroy`, `aec_version`) as an
  abstract Dart interface, with `FfiAecBindings` over `dart:ffi`. Everything
  above the interface is testable with a fake and no native library.
- Add the library loader: explicit path, then `AUDIO_AEC_LIBRARY`, then
  conventional locations beside the executable, then the bare platform file
  name. Failure is a structured `AecUnavailable` listing every path tried, never
  a crash and never a silent degradation.
- Add `AecProcessor`, a main-isolate wrapper over one stateful native instance
  with pre-allocated scratch buffers, an enforced 160-sample/10 ms block
  contract, `metrics()` (ERL/ERLE/residual/delay, native sentinels mapped to
  `null`), and idempotent `dispose()`.
- Add `AecMicFilter`, the `AudioSource`-shaped composition of a microphone
  source and a loopback reference source. Both are consumed eagerly and never
  paused; the reference is zero-padded when the loopback stalls, with matched
  and zero-padded counters exposed; the microphone is buffered so the reference
  leads by a target 80 ms once the delay locks; before lock it is fail-safe
  passthrough; with no processor it is identity.
- Add `tool/build_native.sh`, which builds the native library from
  webrtc-audio-processing v2.1 at a pinned revision into a gitignored `.native/`
  directory. No WebRTC source is vendored. **Binary distribution remains
  unresolved (risk R4): this package ships no binary and requires a
  caller-supplied library.**
- Adapted from Control Center (MIT © 2026 Samuel Alev); the native ABI and build
  script derive from webrtc-audio-processing v2.1 (BSD-3). See `NOTICE`.
