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
  directory. No WebRTC source is vendored.
- **Resolve risk R4 (native distribution) in favour of build hooks.** See
  `doc/DISTRIBUTION.md` for the decision matrix, the measurements, and the
  migration steps.
  - Add `hook/build.dart`: registers the native library as a code asset from a
    local file, a sha256-pinned download, or a meson build from source, in that
    order. It never fails a build — with nothing to offer it prints a diagnostic
    and registers no asset. Configuration is `hooks.user_defines.audio_aec` in
    the workspace-root `pubspec.yaml`, because hooks run in a semi-hermetic
    environment where environment variables are stripped. Downloads are refused
    without a hash pin unless `allow_unpinned: true`.
  - Add `NativeAssetAecBindings`, an `AecBindings` over `@Native` externals
    bound to the hook-registered asset. A code asset has no stable path, so
    `DynamicLibrary.open` cannot reach it; this is a second implementation
    rather than a new candidate in the existing loader, which is unchanged.
  - `AecProcessor.create()` now prefers an explicit `libraryPath`, then the code
    asset, then the previous `AUDIO_AEC_LIBRARY` policy. Consumers who ignore
    build hooks see exactly the previous behaviour.
  - **Fix**: link the macOS dylib with `-headerpad_max_install_names`. The SDK
    rewrites a code asset's install name to an absolute path, which did not fit
    in the default header padding and failed the consumer's build with
    `larger updated load commands do not fit`.
  - Add `example/`, a consumer package that resolves the library through the
    hook with no environment variable set, and `tool/verify_hook.sh`, which
    exercises the download path including a deliberate hash mismatch.
  - Depend on `hooks: ^2.0.0` (not `^2.1.0`, which requires `meta ^1.19.0` and
    cannot resolve alongside Flutter 3.44.0's pinned `meta 1.18.0`),
    `code_assets: ^1.2.1` and `crypto: ^3.0.6`, all used only by the hook.
  - **Known cost**: `dart compile exe` does not support build hooks and fails
    when any dependency has one. Use `dart build cli` instead.
  - No binaries are published yet: `pinnedSha256` is empty, so the hook produces
    nothing until a consumer configures it or the first release ships.
- Adapted from Control Center (MIT © 2026 Samuel Alev); the native ABI and build
  script derive from webrtc-audio-processing v2.1 (BSD-3). See `NOTICE`.
