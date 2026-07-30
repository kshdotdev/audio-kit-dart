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

## Duplex

The default flow is half-duplex with VAD-driven barge-in. Capture can stay
active while STT is gated during playback.

`VoiceDuplexConfig` opts into full duplex, where recognition stays live through
playback so the user can speak over the assistant without losing the start of
the utterance. It requires an echo-cancelled microphone: with the mic open
during playback and nothing removing the speaker bleed, the recognizer hears the
assistant. `voice_flutter`'s `VoiceFullDuplexSetup` builds that composition and
hands back the resolved config.

```dart
final controller = VoiceConversationController(
  input: input,
  backend: backend,
  synthesizer: tts,
  output: output,
  duplex: VoiceDuplexConfig.fullDuplex(),
);
```

What barge-in means in each mode:

| | half duplex | full duplex |
|---|---|---|
| voice activity during playback | interrupts | ignored, unless `interruptAfterSustainedSpeech` is set |
| committed final transcript | starts a new turn | starts a new turn |
| `interruptTurn()` | interrupts | interrupts |

Full duplex requested without echo cancellation resolves to half duplex, and
`duplex.isDegraded` says so. That is deliberate: the degraded mode must never be
worse than the no-AEC baseline. `VoiceEchoCancellationFallback.acceptEchoRisk`
runs full duplex anyway, and is never a default. Every snapshot carries the mode
actually in effect as `duplexMode`.

`voice_core` has no Flutter dependency and no dependency on `audio_aec`; it is
told whether the microphone is clean rather than cleaning it. Use
`voice_flutter` for ready-made graph input/output bridges and widgets.
