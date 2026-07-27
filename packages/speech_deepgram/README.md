# speech_deepgram

Deepgram streaming speech-to-text for the provider-neutral `speech_core`
contracts.

The adapter accepts caller-owned PCM; it does not capture a microphone or own
playback. Audio writes are bounded, credentials come from a renewable token
source, and transport failures use stable `SpeechFailure` codes.

```dart
import 'package:speech_deepgram/speech_deepgram.dart';

final tokenSource = StaticDeepgramTokenSource(
  DeepgramAccessToken(value: apiKey),
);
```

Compose the provider with `audio_flutter` and `audio_kit_graph` to share one
capture with recording, metering, VAD, or additional speech providers.

This release uses a `dart:io` WebSocket transport and does not support web.
