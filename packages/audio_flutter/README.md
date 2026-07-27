# audio_flutter

Provider-neutral Flutter microphone capture, system/process capture, device
discovery, permissions, health events, PCM playback, and native WAV recording.

```dart
import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter/audio_flutter.dart';

final source = FlutterAudioCaptureSource(
  FlutterAudioCaptureConfig(
    type: AudioCaptureType.microphone,
    format: AudioFormat(sampleRate: 16000, channels: 1),
  ),
);

final session = await source.prepare();
final frames = session.frames.listen(routeFrame);
await session.start();
```

Subscribe and attach routes before `start()` so early frames and health events
cannot be lost. Use `audio_kit_graph` when one capture must feed multiple
independent consumers.

The first implementation supports Apple platforms. System/process capture is
macOS-only.
