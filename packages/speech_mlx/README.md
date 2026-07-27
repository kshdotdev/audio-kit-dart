# speech_mlx

Provider-neutral MLX Audio batch recognition and incremental text-to-speech for
`speech_core`. MLX stays a batch inference engine: compose it with VAD and
utterance buffering instead of treating it as a streaming recognizer.

```dart
final provider = MlxSpeechProvider(
  worker: MlxIsolateBatchWorker(
    modelPath: 'mlx-community/parakeet-tdt-0.6b-v2',
  ),
  modelId: 'parakeet-tdt-0.6b-v2',
  ttsWorker: MlxIsolateTtsWorker(
    modelPath: 'mlx-community/pocket-tts',
  ),
  ttsModelId: 'pocket-tts',
  voiceIds: const <String>['alba'],
);

try {
  final result = await provider.transcribe(
    BatchRecognitionRequest(audio: utteranceSource),
  );

  final source = provider.synthesize(
    SpeechSynthesisRequest(
      text: result.text,
      voiceId: 'alba',
      providerOptions: const MlxSynthesisOptions(seed: 7),
    ),
  );
  final session = await source.prepare();
  final frames = session.frames.listen(routeFrame);
  await session.start();
  await frames.cancel();
  await session.close();
} finally {
  await provider.close();
}
```

One `MlxSpeechProvider` advertises every configured capability under the stable
`mlx` provider ID, so it can be registered once without colliding STT and TTS
adapters. Either worker may be omitted when an application needs only one
capability.

`utteranceSource` must be finite, continuous, and within
`maximumInputSamples`. Capture, VAD, utterance buffering, and routing remain
outside the provider. Source-native interleaved PCM crosses the worker boundary;
the long-lived model isolate performs the full concatenation, downmix, and
resampling work away from Flutter's UI isolate.

`MlxIsolateBatchWorker` and `MlxIsolateTtsWorker` load one model per long-lived
isolate and serialize inference. Their request queues are bounded. TTS delivers
real `TtsModel.onAudioChunk` PCM before generation completes and enforces a
finite `maximumOutputSamples` limit before sending chunks, so a stalled
consumer cannot create unbounded cross-isolate storage. The returned audio
source is intentionally non-pausable; attach its single frame stream to an
`AudioRouter` before calling `start`.

Cancelling active synchronous MLX inference terminates the worker isolate
promptly. A later request transparently starts a fresh worker because native MLX
kernels cannot process a Dart port message while a kernel is running.

Use `SerializedMlxBatchWorker` and `SerializedMlxTtsWorker` for deterministic
tests or embedding-specific workers. They serialize calls but do not move work
off the calling isolate. Their close timeout makes cleanup deterministic even
when an injected callback violates the cooperative-cancellation contract.
