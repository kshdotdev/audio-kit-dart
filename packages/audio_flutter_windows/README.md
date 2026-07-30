# audio_flutter_windows

Windows implementation of the `audio_flutter` platform contract: WASAPI
shared-mode loopback for system audio, WASAPI capture endpoints for the
microphone, and a WASAPI render client for playback.

> **The C++ in this package has never been compiled.** It was written on macOS,
> where no MSVC toolchain is available, so the native half is unverified: it has
> been reviewed twice by hand but not built, linked, or run. Build it on a
> Windows machine or in Windows CI before depending on it. The Dart half is
> fully tested and does not share that caveat.

## Mechanism

| Concern | Windows answer |
|---|---|
| System audio | `IAudioClient::Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, …)` on a render endpoint |
| Microphone | the same client on an `eCapture` endpoint, no loopback flag |
| Playback | `IAudioRenderClient` on the default render endpoint |
| Permission | none — shared-mode loopback needs no grant and no OS version gate |
| Format | endpoint mix format is read, never assumed: IEEE float32 and 8/16/24/32-bit integer PCM are decoded, down-mixed to mono, then resampled |
| Resampling | phase-continuous linear interpolation, carried across packet seams |
| Thread | one dedicated capture thread per session, on the MMCSS "Pro Audio" task, polling at half the endpoint buffer in 5 ms slices so stop latency stays bounded |

Audio is **pulled**, not pushed. Each session converts into its own bounded ring
and `readCaptureFrames` drains it. That is the main structural difference from
the Control Center plugin this code is derived from: it pushed every frame to
the platform thread through a private window message, and this one only does
that for the handful of lifecycle events per session.

## Targeting

`PlatformCaptureRequest.inputDeviceId` carries a WASAPI endpoint id for both
capture kinds — an `eCapture` endpoint for the microphone, an `eRender` endpoint
for system audio. Null selects the respective default. `listAudioInputDevices()`
enumerates capture endpoints; `listSystemAudioSources()` enumerates render
endpoints for system-audio targeting.

## Unsupported request fields

Both are rejected at `prepareCapture` rather than ignored, because honouring
them silently would return audio that does not match what was asked for:

* **`processIds`** — per-process capture needs
  `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK` (Windows 10 20H1+), which this
  implementation does not use yet. `listAudioProcesses()` returns empty for the
  same reason. Tracked as a follow-up.
* **`rawRecordingPath`** — no source-side recording. Record from the pulled
  frames instead.

## Overflow policy

`dropOldest` evicts the head and bills the drop to the next frame read;
`dropNewest` refuses the arrival and bills the next frame admitted;
`failCapture` fails the session with `CaptureMailboxOverflow`. `sequence` and
`sampleOffset` are assigned by the producer, so they keep advancing across drops
and a consumer can always tell how much it missed.

## Health

A capture that initialises cleanly but delivers nothing is reported rather than
left hanging: if no audio arrives within two seconds, the session fails with
`CaptureStalled`. Lifecycle events reach Dart over the event channel and are
demultiplexed per session.

## Validation status

| Layer | State |
|---|---|
| Dart platform client, wire codec, session demux | tested, 34 tests |
| C++ WASAPI capture, playback, enumeration | **not compiled, not run** |

See `windows/README.md` for how to build and what to check first on real
hardware.
