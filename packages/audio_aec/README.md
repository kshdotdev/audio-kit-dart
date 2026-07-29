# audio_aec

Acoustic echo cancellation for Audio Kit streams, over WebRTC AEC3.

A microphone picks up whatever is playing out of the speakers. Downstream
recognition transcribes that bleed as a degraded duplicate of the far side,
wrongly attributed to the local speaker. This package feeds a system loopback
capture to AEC3 as the far-end reference and subtracts it from the microphone at
the signal level.

> **This package does not ship a native library.** It is unusable until you
> supply one. See [Native library (risk R4)](#native-library-risk-r4).

## Layers

| Layer | Type | Needs a native library |
|---|---|---|
| Six-symbol C ABI + loader | `AecBindings`, `FfiAecBindings`, `AecUnavailable` | yes |
| One stateful engine instance | `AecProcessor`, `AecEngine`, `AecMetrics` | yes |
| Stream composition | `AecMicFilter`, `AecMicFilterSession` | no (passthrough works) |

The pure math this builds on — envelope cross-correlation delay estimation
(`AecDelayEstimator`) and 10 ms block accumulation (`AecBlockAccumulator`) —
lives in `audio_processing` and needs nothing native.

```dart
import 'package:audio_aec/audio_aec.dart';

final filter = AecMicFilter(
  near: microphoneSource,           // the mic, captured dry
  far: loopbackSource,              // system audio, the far-end reference
  processor: AecProcessor.create(), // throws AecUnavailable if no library
);

final session = await filter.prepare();
session.frames.listen(handleCleanedFrame);
await session.start();
```

With no processor, `AecMicFilter(near: mic)` — or the clearer
`AecMicFilter.passthrough(near: mic)` — reproduces the microphone exactly. That
is the in-person capture mode, where there is no loopback and so nothing to
cancel. It is *not* a fallback for a missing library: that surfaces as
`AecUnavailable`, loudly, rather than quietly recording an echo-laden track.

## Contract

- **Mono float32, 16 kHz.** The engine is created for one sample rate and the
  filter rejects a capture that disagrees, because feeding AEC3 the wrong rate
  produces no error and no cancellation. Resample and downmix upstream.
- **One 10 ms block per native call**, 160 samples at 16 kHz — the unit
  `AudioProcessing::GetFrameSize` defines. `AecProcessor` throws on any other
  size rather than asserting, since a wrong-sized block is a memory-correctness
  problem, not a wrong number. Chunk sizes coming off a capture backend are
  chopped to that unit by `AecBlockAccumulator`.
- **One far-end block per near-end block.** When the loopback stalls, the
  reference is zero-padded rather than left to go stale, and
  `referenceBlocksZeroPadded` counts it.
- **The filter emits a single output**: the cleaned microphone. It consumes the
  far source exclusively as the reference and does not re-emit it. If you also
  need the loopback audio downstream, fan it out with `AudioRouter` before
  handing it here.
- **The output stream cannot be paused.** Pausing would propagate backpressure
  into a realtime capture and starve the engine's render buffer; a stalled
  consumer buffers this filter's own controller instead.

### Capture dry

Do not enable echo cancellation, AGC, or noise suppression on the microphone
device. On macOS that switches it to Voice-Processing I/O, which ducks playback
and breaks the system tap — killing the reference this package needs. Software
AEC exists precisely because the OS-level alternative destroys the loopback.

## Main-isolate only

`AecProcessor` owns a raw native pointer. A pointer is an address in this
process's heap with no ownership attached: it is not sendable across isolates,
and the AEC3 instance behind it is stateful — the adaptive filter, the render
buffer, and the delay estimate all advance with every block, without internal
locking. Every call for a given processor must come from the isolate that
created it.

This is not worth engineering around. Each 10 ms block is sub-millisecond work,
far cheaper than shipping audio over a port, and Audio Kit's stream graph is
main-isolate plumbing already.

## Delay calibration

The microphone and the loopback are two independent operating-system captures
with drifting clocks and a delivery offset that depends entirely on the user's
hardware, so AEC3 alone often never locks onto the echo. `AecDelayEstimator`
measures the real offset live by cross-correlating the two energy envelopes on
one shared arrival clock. The filter then buffers the microphone so the
reference leads by a target 80 ms, and feeds AEC3 a real `stream_delay_ms` that
keeps tracking the live measurement as the clocks drift.

Until that measurement locks, the microphone passes through the engine with no
buffering and no delay hint — never worse than the no-AEC baseline. Watch it
through the session:

```dart
if (session.isLocked) {
  print('lead ${session.streamDelayMs}ms, mic buffer ${session.micBufferMs}ms');
  print('ERLE ${session.metrics().erle}dB');  // > 0 means echo is coming out
}
```

`referenceBlocksMatched` and `referenceBlocksZeroPadded` are the other half of
the picture: a climbing zero-pad count means the reference stream is not keeping
up, and cancellation is degrading for reasons that have nothing to do with the
engine.

## float32 to int16 and back

Audio Kit is float32 end to end. AEC3 is int16-only, so this package is the one
place in the graph where audio makes a lossy round trip:

| Edge | Direction |
|---|---|
| Far-end reference feed | float32 → int16 |
| Capture in and out | float32 → int16 → float32 |

At 16 kHz mono the conversion cost is negligible; the reason to state it is
precision, not performance. One round trip quantizes to within a single step
(`1/32767`). Stacking a second one — running the AEC and then a provider that
demands PCM16 — should be avoided by ordering the graph deliberately, not by
accident. Conversion uses `floatToPcm16` / `pcm16ToFloat` from
`audio_processing`, which clamp rather than wrap.

## Loader resolution order

`AecProcessor.create()` resolves a library by trying, in order:

1. An explicit `libraryPath` argument.
2. The `AUDIO_AEC_LIBRARY` environment variable, naming the library file itself
   (not a directory).
3. Conventional locations beside the running executable: the executable's own
   directory, plus the desktop bundle layout — `../Frameworks` on macOS, `lib/`
   on Linux.
4. The bare platform file name (`libaec_ffi.dylib`, `libaec_ffi.so`,
   `aec_ffi.dll`), letting the operating system's search path resolve it. Note
   that this can also resolve an image the host process has already loaded.

When nothing resolves, or a library resolves but is missing a symbol, you get an
`AecUnavailable` listing every path tried and how to supply one. Nothing
crashes, and there is no silent degradation. An embedder that knows its own
bundle layout can bypass the policy with `FfiAecBindings.openFrom(candidates)`.

## Native library (risk R4)

**Binary distribution is unresolved.** A published pub.dev package cannot use
the reference implementation's approach — out-of-band build scripts writing
dylibs into an application-support directory — and none of the alternatives is
settled:

| Option | Cost | Open question |
|---|---|---|
| `hook/build.dart` native assets | cleanest consumer story | publishing support and stability |
| ffiPlugin building from source | imposes meson and a C++ toolchain on every consumer | the thing the reference implementation's own pubspec argues against |
| Checked-in prebuilt binaries | repo bloat | macOS signing and notarization of a bundled dylib |

Until that is decided, **this package requires a caller-supplied library** and
ships only a build script.

### Building one

`tool/build_native.sh` fetches webrtc-audio-processing at a pinned revision,
builds it static with a bundled static Abseil, and links the shim in
`native/aec_ffi.cc` against it. No WebRTC source is vendored into this
repository.

```bash
packages/audio_aec/tool/build_native.sh
export AUDIO_AEC_LIBRARY="$PWD/packages/audio_aec/.native/libaec_ffi.dylib"
```

Requires `git`, `meson`, `ninja`, `pkg-config`, and a C++ toolchain. Output goes
to the gitignored `.native/`; native artifacts are never committed. The macOS
arm64 path is exercised and produces a self-contained ~2.2 MB dylib depending
only on system frameworks. The Linux path is carried over from the reference
implementation unchanged and is untested here. Windows is not covered.

The script ad-hoc signs the result so it loads locally. That is not distribution
signing — a redistributed macOS dylib needs a Developer ID identity and
notarization, which is one of the open R4 questions above.

### Testing without one

The whole stack above `AecBindings` is exercised with an in-Dart fake, so the
test suite needs no native library. One smoke test calls `aec_version` against a
real library and skips when none is present.

## Attribution

Adapted from Control Center (MIT © 2026 Samuel Alev); the native ABI and the
build script derive from webrtc-audio-processing v2.1 (BSD-3-Clause). See
`NOTICE` — its binary-distribution obligations apply to whoever ships a built
library.
