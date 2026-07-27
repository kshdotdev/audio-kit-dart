# speech_openai_tts

OpenAI text-to-speech exposed through the provider-neutral `speech_core`
contracts.

Synthesis returns a cancellable `AudioSource`. Its PCM can be routed to
playback, recording, metering, or any other bounded Audio Kit branch without
giving the provider ownership of output devices.

```dart
import 'package:speech_openai_tts/speech_openai_tts.dart';

final tokenSource = StaticOpenAiTokenSource(
  OpenAiAccessToken(value: apiKey),
);
```

Credentials are injected through token sources, transport operations are
cancellable, and HTTP/provider failures map to stable `SpeechFailure` values.

See the [Audio Kit repository](https://github.com/kshdotdev/audio-kit-dart)
for voice orchestration examples.
