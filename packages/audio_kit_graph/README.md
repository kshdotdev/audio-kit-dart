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

## Always observe `hub.router.events`

Failure isolation is the point of the design and its one trap: a route that
fails is torn down without disturbing its siblings, so a dead recognizer or a
dropped recording branch is *silent* — no throw, no failed future, just a
pipeline that stopped producing. The router says so; nothing else will.

```dart
hub.router.events.listen((event) {
  if (event is AudioRouteFailed) {
    log.severe('route ${event.routeId} failed: ${event.failure.message}');
  }
});
```

Subscribe before `start`, so a route that fails during startup is still seen.
`AudioRouteGap` on the same stream reports frames an overflow policy discarded.

See the [Audio Kit repository](https://github.com/kshdotdev/audio-kit-dart)
for overflow policies and lifecycle guarantees.
