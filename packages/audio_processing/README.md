# audio_processing

Stateful, provider-neutral PCM processing utilities for Audio Kit.

The package includes resampling, downmixing, rechunking, metering, timeline
synchronization, mixing, and WAV encoding. Transform state is isolated per
track so chunk boundaries do not introduce gaps or reset resamplers.

```dart
import 'package:audio_processing/audio_processing.dart';

final meter = AudioMeter();
final reading = meter.process(frame);
```

File-backed WAV recording is opt-in because it uses `dart:io`:

```dart
import 'package:audio_processing/audio_processing_io.dart';
```

See the [Audio Kit repository](https://github.com/kshdotdev/audio-kit-dart)
for pipeline examples.
