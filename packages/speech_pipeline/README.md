# speech_pipeline

Live transcription over **batch** speech providers for Audio Kit.

Streaming providers emit incremental results on their own. Batch providers — the
common case on Windows, Linux, and anywhere running ONNX models — decode a
finite buffer and return once. This package is the adapter between them: it cuts
a continuous capture stream into windows, skips windows that contain no speech,
decodes them in order, drops recognizer hallucinations, and removes the
microphone's echo of the far-track audio.

```dart
import 'package:speech_pipeline/speech_pipeline.dart';

final pipeline = BatchTranscriptionPipeline(provider: myBatchProvider);

await for (final segment in pipeline.transcribe(session.frames)) {
  print('[${segment.start.inMilliseconds}ms] ${segment.text}');
}
```

## What it contains

| Component | Role |
|---|---|
| `AudioWindowCutter` | Cuts frames into windows on trailing silence (650 ms past a 1500 ms floor) or a 5000 ms cap; silent windows never reach a provider |
| `SpeechActivityDetector` | The gate interface, with an RMS energy default and an `And` combinator for pairing a learned detector with an energy floor |
| `BatchTranscriptionPipeline` | Cutter plus provider plus filters, decoding strictly in capture order |
| Hallucination filters | Drop non-speech markup, degenerate repetitions, and canned boilerplate |
| `TranscriptEchoFilter` | One-directional dedup of near-track windows that echo the far track |

The package is pure Dart and holds no app concepts — no meetings, no
persistence, no UI.

## Two-track echo removal

With speakers rather than headphones the microphone re-hears the far party, so
the same words arrive on both tracks. The far track never captures the
microphone, so it is authoritative: it commits immediately, and a near-track
window that matches it within the emit-time band is dropped. Near windows with
no match yet are briefly held, adaptively, so a late far window can still cancel
them.

```dart
final filter = TranscriptEchoFilter();
filter.accepted.listen(save);
filter.noteFarActivity(clock.elapsed);          // per active far chunk
filter.add(EchoCandidate(role: EchoTrackRole.near, segment: s, emitTime: t));
```

This is a text-level backstop. It is complementary to acoustic echo
cancellation, not a replacement for it.

## Attribution

The window cutter, hallucination filters, echo filter, and speech gate are
derived from [Control Center](https://github.com/SamuelAlev/control-center),
MIT © 2026 Samuel Alev. See `NOTICE`.

See the [Audio Kit repository](https://github.com/kshdotdev/audio-kit-dart) for
pipeline examples.
