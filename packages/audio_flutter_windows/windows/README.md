# Building and validating the Windows native plugin

This C++ has not been compiled. It was written on macOS against the Windows SDK
headers by reference only. Everything below is what a first Windows run needs to
establish.

## Build

There is no example app in this package, so build it through a host app that
depends on `audio_flutter`:

```powershell
flutter build windows --debug
```

CMake picks up `windows/CMakeLists.txt` through the plugin registration in
`pubspec.yaml`. A CI job that only needs to prove the code compiles can build
any minimal Flutter app with `audio_flutter` as a dependency.

## First-run checklist

Expect the first build to surface ordinary porting mistakes. In rough order of
likelihood:

1. **Include order.** `functiondiscoverykeys_devpkey.h` must come *after*
   `mmdeviceapi.h`; on Windows SDK 10.0.26100+ it no longer self-includes the
   `DEFINE_PROPERTYKEY` machinery and every `PKEY_*` reference fails otherwise.
   The `clang-format off` blocks exist to keep that order.
2. **`NOMINMAX`.** Set on the target in CMake. Without it `<windows.h>` defines
   `min`/`max` as macros and every `std::min`/`std::max` call fails.
3. **Link libraries.** `Mmdevapi`, `Ole32`, `Avrt`, `Propsys`. A missing
   `Propsys` shows up as unresolved `PropVariantClear`.
4. **`IID_PPV_ARGS` on `ComPtr::put()`.** If the compiler rejects it, the fix is
   `__uuidof(T), reinterpret_cast<void**>(ptr.put())`.
5. **`FlutterView::GetNativeWindow()`.** The accessor name has moved between
   Flutter versions; `RunOnPlatformThread` is the only caller.

## Runtime checks, in order

1. **Enumeration** — `listAudioInputDevices()` and `listSystemAudioSources()`
   return real names with exactly one `isDefault`.
2. **Loopback produces audio** — start a system-audio capture while something
   plays; frames should be non-silent and `CaptureStalled` should not fire.
3. **Silence is still delivered** — with nothing playing, frames should keep
   arriving as zeros rather than stopping (the `AUDCLNT_BUFFERFLAGS_SILENT`
   path); the watchdog only fires when the endpoint delivers no packets at all.
4. **Mix-format decode** — test a 48 kHz float32 endpoint (typical) and, if any
   hardware is available, a 44.1 kHz or 24-bit endpoint. The resampler carries a
   fractional cursor across packets, so listen for clicks at packet seams.
5. **Microphone path** — same, on an `eCapture` endpoint, and confirm no DSP is
   applied: this plugin deliberately does not enable any voice-processing mode,
   because AEC belongs in `audio_aec` downstream and the platform DSP would
   corrupt the reference signal.
6. **Overflow policies** — stop pulling and confirm `dropOldest` keeps the
   newest audio, `dropNewest` keeps the oldest, `failCapture` raises
   `CaptureMailboxOverflow`, and `droppedFramesBefore` accounts for every gap.
7. **Stop latency** — `stopCapture` should return within roughly one poll
   interval (5–100 ms), not one full endpoint buffer.
8. **Playback** — write float32 frames and confirm the render path converts to
   the endpoint mix format at the right rate, and that `finishPlayback` drains
   rather than truncating.
9. **Device changes** — unplug the default endpoint mid-capture. The session
   should fail loudly rather than deliver silence forever; if it hangs instead,
   a device-notification client is the fix.
10. **Concurrency** — one microphone and one loopback capture at once, which is
    the meeting case, plus playback alongside them.

## Known gaps

* Per-process loopback (`AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`) is not
  implemented; `processIds` is rejected instead.
* No source-side recording; `rawRecordingPath` is rejected.
* No `IMMNotificationClient`, so a default-device change mid-session is not
  followed.
