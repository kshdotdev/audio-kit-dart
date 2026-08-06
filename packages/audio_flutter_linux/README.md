# audio_flutter_linux

Linux implementation of the `audio_flutter` platform contract: microphone and
system-audio capture, plus PCM playback, over the PulseAudio/PipeWire
command-line tools.

The package contains **no native code**. Capture spawns `parecord` and falls
back to `pw-record`; playback spawns `paplay` and falls back to `pw-play`. Both
are asked for signed 16-bit little-endian PCM at the requested rate and channel
count, which this package converts to and from the float32 frames the contract
carries. Registration is `dartPluginClass` only — there is no C++ registrant to
build.

## Targeting

PulseAudio exposes one flat source namespace: hardware inputs
(`alsa_input.*`) and sink monitors (`alsa_output.*.monitor`) are both sources
addressable by name. `PlatformCaptureRequest.inputDeviceId` therefore carries a
**PulseAudio source name** for both capture kinds:

| Capture kind | `inputDeviceId` set | `inputDeviceId` null |
|---|---|---|
| `microphone` | that source is recorded | the tool's own default input |
| `systemAudio` | that source is recorded (and must be a `.monitor`) | the default sink's monitor, resolved with `pactl get-default-sink` |

Application capture combines the normalized source's `inputDeviceId` selector
with its exact `processIds`; ordinary microphone and monitor capture still use
the same source namespace. A missing or non-monitor system-audio selector is
rejected rather than falling back to the default microphone.

`listAudioInputDevices()` returns the non-monitor sources.
`listSystemAudioSources()` — a Linux-only addition, not part of the platform
contract — returns the monitors, so a UI can offer them for selection.

For isolated application capture, Pulse-compatible sound servers expose active
render streams as sink inputs. `pactl --format=json list sink-inputs` supplies
the stream index and local process metadata; `parecord --monitor-stream=INDEX`
uses PulseAudio's `pa_stream_set_monitor_stream` path to record exactly that
stream. PipeWire hosts are supported through `pipewire-pulse` when they expose
the same sink-input contract.

Each addressable stream is a normalized application/browser source with its
exact PID. The stream is revalidated at prepare and again immediately before
allocation. A broader
PID set is rejected because one sink-input selector cannot represent it, and
`pw-record` is deliberately not used as a fallback for these sources because it
would broaden capture to a node or monitor mix.

## Permissions

Linux has no system-audio permission gate: monitor sources are readable by any
client of the running sound server. `isSystemAudioCaptureSupported()` reports
whether a capture tool and `pactl` are installed **and a monitor is actually
exposed**, and
`requestSystemAudioCapturePermission()` mirrors it. Both answer "is the
mechanism present", never "did a user grant something".

## Format support

Formats map straight onto process arguments (`--rate`, `--channels`), so any
rate up to 192 kHz and up to 32 channels is accepted. Combinations PulseAudio
cannot express — or a frame duration too short to hold one whole sample frame —
are rejected from `prepareCapture`/`preparePlayback` with a
`LinuxAudioFormatException` rather than failing mid-capture.

## Health

`captureEvents` reports `starting`, then `running` with `receivingAudio: true`
once bytes actually arrive. A source that starts cleanly but delivers nothing
fails after two seconds with code `SystemCaptureDead`, matching the Darwin
watchdog. An unexpected tool exit fails with `CaptureProcessExited` and an
excerpt of the child's stderr. The child's stderr is always drained, because an
unread pipe fills its kernel buffer and blocks the process.

## Backpressure

`readCaptureFrames` pulls from a bounded ring sized by
`maxBufferedDuration ÷ frameDuration`, honouring every
`PlatformCaptureOverflowPolicy`. Frame `sequence` and `sampleOffset` are
assigned as audio is produced, so they keep advancing across drops and the
frame delivered after a gap reports `droppedFramesBefore`. Playback
backpressure is the child's stdin: every write awaits its flush.

## Status

**Not yet validated against a real PulseAudio or PipeWire server.** Every
command line, parse, and lifecycle path is unit-tested through an injected
process seam, and that suite runs on any host — but no audio has been captured
or played on Linux hardware. Treat argument compatibility across PulseAudio and
PipeWire versions, sink-input monitoring, monitor availability, and end-to-end
latency as unverified until that run happens. Native PipeWire nodes without the
Pulse compatibility service remain explicit unavailable application sources;
they are never treated as isolated merely because `pw-record` can name a node.

## Attribution

Command assembly, `pactl` parsing, monitor resolution, the capture-tool
fallback order, and the always-drain-stderr rule are derived from Control
Center, MIT © 2026 Samuel Alev. See `NOTICE`.
