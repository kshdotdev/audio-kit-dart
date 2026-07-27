# voice_core

Cancellable, provider-neutral voice conversation and turn orchestration.

Session state (`preparing`, `active`, `stopping`, `failed`) is independent from
turn state (`listening`, `thinking`, `speaking`, `interrupted`). Generation IDs
reject stale events after cancellation, while serialized sentence synthesis
preserves output order.

```dart
import 'package:voice_core/voice_core.dart';

final segmenter = IncrementalSentenceSegmenter();
final sentences = segmenter.add('Hello. How are you?');
```

The default flow is half-duplex with VAD-driven barge-in. Capture can stay
active while STT is gated during playback.

`voice_core` has no Flutter dependency. Use `voice_flutter` for ready-made
graph input/output bridges and widgets.
