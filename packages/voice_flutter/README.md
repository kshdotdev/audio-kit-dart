# voice_flutter

Graph-backed Flutter voice input/output bridges and optional widgets driven by
`voice_core` state.

`GraphVoiceInput` routes one capture to independent streaming STT and VAD
sessions. `GraphVoiceSpeechOutput` routes every synthesized source to playback
and optional recording, metering, or analysis branches.

```dart
import 'package:voice_flutter/voice_flutter.dart';

final input = GraphVoiceInput(
  source: microphoneSource,
  streamingSpeechToText: selectedStt,
  voiceActivityDetection: selectedVad,
  recognitionOptions: recognitionOptions,
);
```

When half-duplex output gates recognition, only the STT session is replaced;
capture and VAD remain active for barge-in. Provider selection stays in the
application composition layer.
