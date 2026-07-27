# speech_fluidaudio

FluidAudio adapters for the provider-neutral `speech_core` contracts.

The package exposes streaming and batch STT, VAD, end-of-utterance detection,
batch diarization, and TTS while keeping `fluidaudio_dart` types inside the
adapter boundary.

```dart
import 'package:speech_fluidaudio/speech_fluidaudio.dart';

final provider = FluidAudioSpeechProvider(runtime: FluidNativeRuntime());
```

Capture and playback remain in `audio_flutter`. This lets one capture feed
FluidAudio, recording, meters, or another cloud/local provider through the
same `audio_kit_graph`.

FluidAudio inference is on-device and currently targets supported Apple
platforms.
