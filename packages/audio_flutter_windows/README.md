# audio_flutter_windows

Windows implementation of the `audio_flutter` platform contract: WASAPI
shared-mode loopback for system audio, application-loopback capture for exact
process trees, WASAPI capture endpoints for the microphone, and a WASAPI render
client for playback.

The C++ translation units are cross-compiled against Windows headers in local
validation and the repository's `windows-desktop` job builds the complete
Flutter plugin with MSVC. Hardware capture still requires the clean-machine
Windows matrix described below.

## Mechanism

| Concern | Windows answer |
|---|---|
| System audio | `IAudioClient::Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, …)` on a render endpoint |
| Application audio | one `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK` client per independent requested process tree; QPC-aligned clients are clipped and mixed |
| Microphone | the same client on an `eCapture` endpoint, no loopback flag |
| Playback | `IAudioRenderClient` on the default render endpoint |
| Permission | none — shared-mode loopback needs no grant and no OS version gate |
| Format | endpoint mix format is read, never assumed: IEEE float32 and 8/16/24/32-bit integer PCM are decoded, down-mixed to mono, then resampled |
| Resampling | phase-continuous linear interpolation, carried across packet seams |
| Clock | WASAPI QPC positions converted to the shared `windows.qpc` monotonic clock |
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

When `processIds` is non-empty, `inputDeviceId` must be null. The native host
activates every independent requested process tree and never falls back to an
endpoint mix. Windows' API includes descendants of each selected PID by
definition; if both an ancestor and descendant are selected, the redundant
descendant client is removed to avoid double mixing.

Microsoft documents process loopback from OS build **20348**. Windows 11 and
newer supported builds expose application/browser sources. Windows 10 22H2
(build 19045) remains supported for the app, microphone, playback, and explicit
system-mix capture, but application isolation is reported unavailable with
`windows_process_loopback_os_unsupported`.

## Unsupported request fields

`rawRecordingPath` is rejected at `prepareCapture` rather than ignored because
source-side recording is not implemented. Record from the pulled frames
instead.

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
| Dart platform client, wire codec, session demux | unit-tested |
| C++ translation units | cross-compiler validated; MSVC build runs in Windows CI |
| Real process/system capture | requires Windows 11 clean-machine hardware validation |

See `windows/README.md` for how to build and what to check first on real
hardware.
