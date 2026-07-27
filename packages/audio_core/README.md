# audio_core

Provider-neutral PCM types and asynchronous source/sink session contracts for
Dart and Flutter audio applications.

`AudioFrame` owns interleaved float32 PCM and carries format, source, track,
clock, sequence, sample-offset, timestamp, and discontinuity metadata.
`AudioSource` and `AudioSink` use two-phase `prepare`/`start` lifecycles so
consumers can attach every listener before the first frame is emitted.

```dart
import 'package:audio_core/audio_core.dart';

final format = AudioFormat(sampleRate: 16000, channels: 1);
```

This package has no Flutter or provider SDK dependency. Use
[`audio_kit_graph`](https://pub.dev/packages/audio_kit_graph) for bounded
fan-out and [`audio_processing`](https://pub.dev/packages/audio_processing)
for PCM transforms.

See the [Audio Kit repository](https://github.com/kshdotdev/audio-kit-dart)
for architecture and lifecycle documentation.
