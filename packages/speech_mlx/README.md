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

## Turn completion

`MlxSmartTurnScorer` implements `TurnCompletionScorer` over the pinned Smart
Turn v3.2 classifier: given the audio leading up to a pause, it answers whether
the speaker was *finished*, which is the question a silence timeout cannot ask.

```dart
final scorer = MlxSmartTurnScorer(worker: MlxIsolateTurnWorker());

try {
  final score = await scorer.scoreTurnCompletion(
    // A ring-buffer slice ending at the pause. Trailing silence belongs in it.
    TurnCompletionRequest.fromSamples(window),
  );
  if (score.isComplete) endTurn(score.probability);
} finally {
  await scorer.close();
}
```

It is a separate provider from `MlxSpeechProvider` on purpose: the two own
different checkpoints with different lifecycles, and a detector usually wants
the turn model resident long before any transcription runs. It advertises only
`SpeechCapability.turnCompletion`, under the same stable `mlx` provider ID.

`MlxIsolateTurnWorker` takes no model path — Smart Turn is pinned by revision
and per-file SHA-256 inside `mlx_audio`, so the only knob is `modelDirectory`
for an already-materialized snapshot. Loading caps MLX's buffer cache and warms
the Metal kernels on silence, so the first real pause sees steady-state latency
(~5 ms per 8 s window after warmup, vs ~1.8 s cold).

Windows longer than the classifier's 8 s are cropped to their **tail** before
the isolate hop, and shorter ones are left-padded by the model: the decision is
about how the audio ended. Windows at another sample rate keep it — resampling
happens next to the model, with the same polyphase filter `mlx_audio` uses
elsewhere. Scoring failures raise `SpeechFailure`; the scorer never invents a
probability to keep a caller running, because a made-up `0.5` is
indistinguishable from a genuinely uncertain model.
