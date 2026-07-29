import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:speech_mlx/speech_mlx.dart';
import 'package:test/test.dart';

Float32List _window(int sampleCount) =>
    Float32List.fromList(List<double>.filled(sampleCount, 0.25));

MlxTurnWorkerResult _complete({double probability = 0.9}) =>
    MlxTurnWorkerResult(
      probability: probability,
      isComplete: probability > 0.5,
      threshold: 0.5,
    );

void main() {
  test('scorer advertises turn completion and forwards the window', () async {
    MlxTurnWorkerRequest? observed;
    var disposeCount = 0;
    final worker = SerializedMlxTurnWorker(
      infer: (request, cancellation) {
        observed = request;
        return _complete(probability: 0.87);
      },
      dispose: () => disposeCount++,
    );
    final scorer = MlxSmartTurnScorer(worker: worker);

    final score = await scorer.scoreTurnCompletion(
      TurnCompletionRequest.fromSamples(_window(16000)),
    );

    expect(scorer.descriptor.capabilities, const <SpeechCapability>{
      SpeechCapability.turnCompletion,
    });
    expect(scorer.descriptor.models.single.id, mlxSmartTurnModelId);
    expect(scorer.descriptor.models.single.isLocal, isTrue);
    expect(score.probability, 0.87);
    expect(score.isComplete, isTrue);
    expect(score.threshold, 0.5);
    expect(observed, isNotNull);
    expect(observed!.sampleCount, 16000);
    expect(observed!.sampleRate, TurnCompletionAudio.sampleRate);
    expect(observed!.modelId, mlxSmartTurnModelId);
    expect(observed!.threshold, isNull);

    await scorer.close();
    await scorer.close();
    expect(disposeCount, 1);
  });

  test('a per-request threshold reaches the worker', () async {
    MlxTurnWorkerRequest? observed;
    final scorer = MlxSmartTurnScorer(
      worker: SerializedMlxTurnWorker(
        infer: (request, cancellation) {
          observed = request;
          return MlxTurnWorkerResult(
            probability: 0.4,
            isComplete: true,
            threshold: 0.2,
          );
        },
      ),
    );
    addTearDown(scorer.close);

    final score = await scorer.scoreTurnCompletion(
      TurnCompletionRequest.fromSamples(_window(8000), threshold: 0.2),
    );
    expect(observed!.threshold, 0.2);
    expect(score.threshold, 0.2);
    expect(score.isComplete, isTrue);
  });

  test('an over-long window is cropped to its tail before the hop', () async {
    MlxTurnWorkerRequest? observed;
    final scorer = MlxSmartTurnScorer(
      worker: SerializedMlxTurnWorker(
        infer: (request, cancellation) {
          observed = request;
          return _complete();
        },
      ),
    );
    addTearDown(scorer.close);

    // 20 s at 16 kHz; the classifier reads the trailing 8 s.
    final samples = Float32List(20 * 16000);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = i.toDouble();
    }
    await scorer.scoreTurnCompletion(
      TurnCompletionRequest.fromSamples(samples),
    );

    expect(observed!.sampleCount, 8 * 16000);
    // The TAIL, not the head: the decision is about how the audio ended.
    expect(observed!.samples.first, samples[samples.length - 8 * 16000]);
    expect(observed!.samples.last, samples.last);
  });

  test('a short window is passed through untouched', () async {
    MlxTurnWorkerRequest? observed;
    final scorer = MlxSmartTurnScorer(
      worker: SerializedMlxTurnWorker(
        infer: (request, cancellation) {
          observed = request;
          return _complete();
        },
      ),
    );
    addTearDown(scorer.close);

    await scorer.scoreTurnCompletion(
      TurnCompletionRequest.fromSamples(_window(1600)),
    );
    expect(observed!.sampleCount, 1600);
  });

  test(
    'a non-16 kHz window keeps its own rate for the model to resample',
    () async {
      MlxTurnWorkerRequest? observed;
      final scorer = MlxSmartTurnScorer(
        worker: SerializedMlxTurnWorker(
          infer: (request, cancellation) {
            observed = request;
            return _complete();
          },
        ),
      );
      addTearDown(scorer.close);

      // 20 s at 48 kHz crops to 8 s at 48 kHz — the crop is rate-aware.
      await scorer.scoreTurnCompletion(
        TurnCompletionRequest.fromSamples(
          Float32List(20 * 48000),
          sampleRate: 48000,
        ),
      );
      expect(observed!.sampleRate, 48000);
      expect(observed!.sampleCount, 8 * 48000);
    },
  );

  test('foreign provider options are rejected', () async {
    final scorer = MlxSmartTurnScorer(
      worker: SerializedMlxTurnWorker(
        infer: (request, cancellation) => _complete(),
      ),
    );
    addTearDown(scorer.close);

    await expectLater(
      scorer.scoreTurnCompletion(
        TurnCompletionRequest.fromSamples(
          _window(1600),
          providerOptions: const _ForeignOptions(),
        ),
      ),
      throwsA(
        isA<SpeechFailure>().having(
          (SpeechFailure f) => f.code,
          'code',
          'invalid_provider_options',
        ),
      ),
    );
  });

  test('a mismatched model id is rejected', () async {
    final scorer = MlxSmartTurnScorer(
      worker: SerializedMlxTurnWorker(
        infer: (request, cancellation) => _complete(),
      ),
    );
    addTearDown(scorer.close);

    await expectLater(
      scorer.scoreTurnCompletion(
        TurnCompletionRequest.fromSamples(
          _window(1600),
          providerOptions: const MlxSmartTurnOptions(modelId: 'other'),
        ),
      ),
      throwsA(
        isA<SpeechFailure>().having(
          (SpeechFailure f) => f.code,
          'code',
          'unknown_model',
        ),
      ),
    );

    // The scorer's own id passes.
    final score = await scorer.scoreTurnCompletion(
      TurnCompletionRequest.fromSamples(
        _window(1600),
        providerOptions: const MlxSmartTurnOptions(
          modelId: mlxSmartTurnModelId,
        ),
      ),
    );
    expect(score.isComplete, isTrue);
  });

  test(
    'worker failures surface as SpeechFailure, never as a fake score',
    () async {
      final scorer = MlxSmartTurnScorer(
        worker: SerializedMlxTurnWorker(
          infer: (request, cancellation) => throw StateError('metal exploded'),
        ),
      );
      addTearDown(scorer.close);

      await expectLater(
        scorer.scoreTurnCompletion(
          TurnCompletionRequest.fromSamples(_window(1600)),
        ),
        throwsA(
          isA<SpeechFailure>()
              .having((SpeechFailure f) => f.code, 'code', 'inference_failed')
              .having((SpeechFailure f) => f.stage, 'stage', 'turn_completion')
              .having(
                (SpeechFailure f) => f.providerId,
                'providerId',
                mlxSpeechProviderId,
              ),
        ),
      );
    },
  );

  test('a full worker queue is retryable, not fatal', () async {
    final release = Completer<void>();
    final worker = SerializedMlxTurnWorker(
      maximumQueuedRequests: 1,
      infer: (request, cancellation) async {
        await release.future;
        return _complete();
      },
    );
    final scorer = MlxSmartTurnScorer(worker: worker);

    final first = scorer.scoreTurnCompletion(
      TurnCompletionRequest.fromSamples(_window(1600)),
    );
    await pumpEventQueue();

    await expectLater(
      scorer.scoreTurnCompletion(
        TurnCompletionRequest.fromSamples(_window(1600)),
      ),
      throwsA(
        isA<SpeechFailure>()
            .having(
              (SpeechFailure f) => f.code,
              'code',
              'mlx_turn_completion_busy',
            )
            .having((SpeechFailure f) => f.retryable, 'retryable', isTrue),
      ),
    );

    release.complete();
    expect((await first).isComplete, isTrue);
    await scorer.close();
  });

  test('scoring after close throws StateError', () async {
    final scorer = MlxSmartTurnScorer(
      worker: SerializedMlxTurnWorker(
        infer: (request, cancellation) => _complete(),
      ),
    );
    await scorer.close();
    expect(scorer.isClosed, isTrue);
    expect(
      () => scorer.scoreTurnCompletion(
        TurnCompletionRequest.fromSamples(_window(1600)),
      ),
      throwsStateError,
    );
  });

  test('a pre-cancelled request never reaches the worker', () async {
    var calls = 0;
    final scorer = MlxSmartTurnScorer(
      worker: SerializedMlxTurnWorker(
        infer: (request, cancellation) {
          calls++;
          return _complete();
        },
      ),
    );
    addTearDown(scorer.close);

    final cancellation = AudioCancellationController()..cancel();
    expect(
      () => scorer.scoreTurnCompletion(
        TurnCompletionRequest.fromSamples(
          _window(1600),
          cancellation: cancellation.token,
        ),
      ),
      throwsA(isA<AudioCancelledException>()),
    );
    await pumpEventQueue();
    expect(calls, 0);
  });

  group('MlxTurnWorkerRequest', () {
    test('copies the caller\'s buffer', () {
      final samples = _window(4);
      final request = MlxTurnWorkerRequest(
        samples: samples,
        sampleRate: 16000,
        modelId: mlxSmartTurnModelId,
      );
      samples[0] = -1;
      expect(request.samples[0], 0.25);
    });

    test('rejects malformed inputs', () {
      expect(
        () => MlxTurnWorkerRequest(
          samples: Float32List(0),
          sampleRate: 16000,
          modelId: mlxSmartTurnModelId,
        ),
        throwsArgumentError,
      );
      expect(
        () => MlxTurnWorkerRequest(
          samples: _window(4),
          sampleRate: 0,
          modelId: mlxSmartTurnModelId,
        ),
        throwsArgumentError,
      );
      expect(
        () => MlxTurnWorkerRequest(
          samples: _window(4),
          sampleRate: 16000,
          modelId: '  ',
        ),
        throwsArgumentError,
      );
      expect(
        () => MlxTurnWorkerRequest(
          samples: _window(4),
          sampleRate: 16000,
          modelId: mlxSmartTurnModelId,
          threshold: 1.5,
        ),
        throwsArgumentError,
      );
    });
  });

  group('MlxTurnWorkerResult', () {
    test('rejects out-of-range probabilities and thresholds', () {
      expect(
        () => MlxTurnWorkerResult(
          probability: 1.2,
          isComplete: true,
          threshold: 0.5,
        ),
        throwsArgumentError,
      );
      expect(
        () => MlxTurnWorkerResult(
          probability: 0.5,
          isComplete: false,
          threshold: double.nan,
        ),
        throwsArgumentError,
      );
    });
  });

  group('MlxIsolateTurnWorker', () {
    test('validates its limits up front', () {
      expect(
        () => MlxIsolateTurnWorker(inputSampleRate: 0),
        throwsArgumentError,
      );
      expect(
        () => MlxIsolateTurnWorker(maximumQueuedRequests: 0),
        throwsArgumentError,
      );
      expect(
        () => MlxIsolateTurnWorker(maximumWindow: Duration.zero),
        throwsArgumentError,
      );
    });

    test('closing a never-started worker is a no-op', () async {
      final worker = MlxIsolateTurnWorker();
      await worker.close();
      await worker.close();
      await expectLater(
        worker.score(
          MlxTurnWorkerRequest(
            samples: _window(16),
            sampleRate: 16000,
            modelId: mlxSmartTurnModelId,
          ),
        ),
        throwsStateError,
      );
    });
  });
}

final class _ForeignOptions implements SpeechProviderOptions {
  const _ForeignOptions();

  @override
  String get providerId => 'other';
}
