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

## Full duplex

`VoiceFullDuplexSetup.compose` builds the opt-in full-duplex composition: the
microphone is cleaned by `audio_aec` instead of gated, so the user can speak over
the assistant without losing the start of the utterance.

```dart
final setup = VoiceFullDuplexSetup.compose(
  microphone: rawMicrophoneSource,
  captureFormat: AudioFormat(sampleRate: 16000, channels: 1),
);

final controller = VoiceConversationController(
  input: GraphVoiceInput(
    source: setup.microphone,
    streamingSpeechToText: stt,
    voiceActivityDetection: vad,
  ),
  backend: backend,
  synthesizer: tts,
  output: GraphVoiceSpeechOutput(
    playbackSink: deviceSink,
    extraRoutes: setup.outputRoutes,
  ),
  duplex: setup.duplex,
);
```

The far-end reference is the actual playback signal, not a re-synthesis of it.
`VoiceFarEndTap` attaches beside device playback, so one router dispatch delivers
each synthesized frame to the speakers and to the canceller in the same order.

Four things worth knowing:

- **The reference must match the capture format.** A tap prepared at a different
  rate or channel count is rejected loudly, because a mismatched reference
  produces no error and no cancellation. Resample the synthesized audio upstream.
- **Capture must be dry.** Leave platform echo cancellation and AGC off on the
  microphone; software cancellation needs the signal the reference describes.
- **Degradation is explicit.** With no native AEC library, `compose` returns the
  raw microphone and a half-duplex policy (`setup.duplex.isDegraded`), carrying
  the structured `AecUnavailable` and every path the loader tried. Full duplex
  without cancellation requires `VoiceEchoCancellationFallback.acceptEchoRisk`.
- **One composition, one session.** `AecMicFilter` binds a single stateful native
  engine, so the composed input cannot be restarted after `stop()`. Compose again.

`audio_aec` ships no native binary; see its README for the loader's resolution
order.
