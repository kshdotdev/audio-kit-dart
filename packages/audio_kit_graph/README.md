# audio_kit_graph

Bounded, failure-isolated N-way audio routing built on `audio_core`.

Each route has its own mailbox, capacity, overflow policy, lifecycle, metrics,
and discontinuity reporting. A slow meter or network provider cannot block a
realtime capture callback or corrupt a healthy recording branch.

```dart
import 'package:audio_kit_graph/audio_kit_graph.dart';

final hub = await AudioHub.prepare(source);
hub.attachPrepared(
  id: 'primary-stt',
  sink: preparedSpeechSession,
  options: AudioRouteOptions.lossless(
    capacityFrames: 20,
    capacitySampleFrames: 32000,
  ),
);
await hub.start();
```

Ordering is guaranteed per source and route. Synchronizing or mixing separate
microphone and system-audio clocks is an explicit `audio_processing` step.

See the [Audio Kit repository](https://github.com/kshdotdev/audio-kit-dart)
for overflow policies and lifecycle guarantees.
