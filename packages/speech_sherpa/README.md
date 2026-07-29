# speech_sherpa

Cross-platform implementation of the provider-neutral speech contracts, backed
by [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). This is the inference
floor for every platform without an on-device Apple runtime: the same models
run on macOS, Windows, Linux, iOS, and Android through ONNX Runtime.

```dart
final registry = SherpaModelRegistry(root: modelsDirectory);
await registry.installRecognition(SherpaRecognitionModel.defaultModel);

final provider = SherpaSpeechProvider(registry: registry);
final result = await provider.transcribe(
  BatchRecognitionRequest(audio: recordedFile),
);
print(result.text);
await provider.close();
```

## Capabilities

| Capability | Status |
| --- | --- |
| Batch speech-to-text | Implemented |
| Voice-activity detection | Implemented (Silero) |
| Diarization | Implemented (pyannote + WeSpeaker) |
| Speaker embeddings | Implemented, provenance-tagged |
| Streaming speech-to-text | **Not implemented** — see below |
| Text-to-speech | Not implemented |

sherpa-onnx does expose an `OnlineRecognizer` with published streaming Zipformer
models, so cross-platform streaming recognition is possible; it is simply not
wired here yet. The provider does not declare
`SpeechCapability.streamingSpeechToText` until it is, because a declared
capability is a promise rather than an aspiration. Until then, pair this
provider with `speech_pipeline`, which turns any batch provider into a live
transcript by cutting rolling windows.

## Platforms

| Platform | Notes |
| --- | --- |
| macOS | x64 and arm64 |
| Windows | x64 |
| Linux | x64 |
| iOS | arm64 |
| Android | arm64, armeabi-v7a, x86, x86_64 |

Native libraries ship with the `sherpa_onnx` platform packages. A host that
cannot resolve the library by leaf name can pass a directory to
`SherpaNativeRuntime(libraryDirectory: ...)`.

## Models

Nothing is bundled. The registry downloads on demand into a directory you
supply, so the SDK never guesses at an application's storage layout.

| Model | Kind | Approx. size | Languages |
| --- | --- | --- | --- |
| Parakeet TDT 0.6B v3 int8 (default) | transducer | 600 MB | 25 European |
| Parakeet TDT 0.6B v2 int8 | transducer | 480 MB | English |
| Whisper large-v3-turbo int8 | whisper | 626 MB | 99+ |
| Whisper base.en int8 | whisper | 198 MB | English |
| Silero VAD | vad | 2 MB | — |
| pyannote segmentation 3.0 | diarization | 9 MB | — |
| WeSpeaker ResNet34 (VoxCeleb) | embedding | 26 MB | English |

Recognition weights are hundreds of megabytes. Call
`SherpaSpeechProvider.unloadRecognizer()` when a recording session ends to
release them; the next `transcribe` reloads lazily.

## Two gotchas worth knowing

Both are encoded in this package, and both are easy to reintroduce by
"cleaning up" the code that looks redundant.

**`modelType` stays empty.** sherpa auto-routes NeMo-Parakeet versus k2-Zipformer
from the model metadata. Setting `modelType: 'transducer'` — which reads like the
obviously correct value — makes every Parakeet model fail on a `vocab_size`
metadata lookup.

**Bindings are per-isolate.** sherpa resolves its native symbols into
isolate-local statics, so every isolate touching the API must call
`ensureSherpaBindings()` for itself. Skipping it in a worker surfaces as
`Please initialize sherpa-onnx first`, which reads like a missing model rather
than a missing symbol.

## Threading

A batch decode is a synchronous FFI call lasting hundreds of milliseconds to
seconds. Recognition therefore runs on a long-lived worker isolate, with audio
crossing as `TransferableTypedData`; diarization uses a throwaway isolate,
because it runs once per recording rather than once per window. Audio stays
`Float32List` end to end — sherpa consumes float32 natively, so there is no
PCM16 detour.

## Testing

Unit tests inject a fake `SherpaRuntime` and run without ONNX Runtime, model
files, or isolates. Tests that exercise the real native path are gated behind an
environment variable so CI never downloads 600 MB:

```sh
SPEECH_SHERPA_MODELS=~/models flutter test --tags integration
```

## Attribution

The worker-isolate transcriber, model registry, and diarization configuration
are derived from [Control Center](https://github.com/SamuelAlev/control-center),
MIT © 2026 Samuel Alev. See `NOTICE`. sherpa-onnx itself is Apache-2.0,
© k2-fsa.
