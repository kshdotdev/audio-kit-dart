# speech_core

Provider-neutral speech recognition, synthesis, VAD, end-of-utterance, and
diarization contracts.

Providers expose stable string IDs plus typed capability, model, voice,
request, result, and failure objects. Provider SDK objects and untyped payload
maps stay inside adapter packages.

```dart
import 'package:speech_core/speech_core.dart';

final registry = SpeechProviderRegistry();
registry.register(provider);
```

Streaming STT, VAD, and EOU sessions are audio sinks. TTS is an `AudioSource`,
so synthesized PCM can branch to playback, recording, metering, or analysis.

Available adapters in this repository include FluidAudio, MLX Audio, Deepgram,
and OpenAI TTS.
