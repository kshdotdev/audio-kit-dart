import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:speech_mlx/speech_mlx.dart';
import 'package:test/test.dart';

void main() {
  test('one registry entry advertises configured MLX STT and TTS', () async {
    var closedWorkers = 0;
    final batchWorker = SerializedMlxBatchWorker(
      inputSampleRate: 16000,
      infer: (request, cancellation, onProgress) =>
          MlxBatchWorkerResult(text: '', segments: const []),
      dispose: () => closedWorkers += 1,
    );
    final ttsWorker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      infer: (request, cancellation, onAudioChunk) => const MlxTtsWorkerResult(
        sampleRate: 24000,
        sampleCount: 0,
        frameCount: 0,
      ),
      dispose: () => closedWorkers += 1,
    );
    final provider = MlxSpeechProvider(
      worker: batchWorker,
      ttsWorker: ttsWorker,
    );
    final registry = SpeechProviderRegistry()..register(provider);

    expect(provider.descriptor.capabilities, <SpeechCapability>{
      SpeechCapability.batchSpeechToText,
      SpeechCapability.textToSpeech,
    });
    expect(registry[mlxSpeechProviderId], same(provider));
    expect(
      registry.supporting<TextToSpeechProvider>(SpeechCapability.textToSpeech),
      orderedEquals(<TextToSpeechProvider>[provider]),
    );

    await registry.close();
    expect(closedWorkers, 2);
  });

  test('emits the first PCM chunk before generation completes', () async {
    final finishGeneration = Completer<void>();
    final worker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      infer: (request, cancellation, onAudioChunk) async {
        onAudioChunk(_chunk(<double>[0.1, 0.2], frameIndex: 0, offset: 0));
        await finishGeneration.future;
        return const MlxTtsWorkerResult(
          sampleRate: 24000,
          sampleCount: 2,
          frameCount: 1,
        );
      },
    );
    final provider = MlxSpeechProvider(ttsWorker: worker);
    final session = await provider
        .synthesize(SpeechSynthesisRequest(text: 'Hello'))
        .prepare();
    final firstFrame = Completer<AudioFrame>();
    final subscription = session.frames.listen((frame) {
      if (!firstFrame.isCompleted) {
        firstFrame.complete(frame);
      }
    });
    expect(() => subscription.pause(), throwsUnsupportedError);
    var generationCompleted = false;
    final generation = session.start().whenComplete(
      () => generationCompleted = true,
    );

    final frame = await firstFrame.future;
    expect(generationCompleted, isFalse);
    expect(frame.samples[0], closeTo(0.1, 1e-6));
    expect(frame.samples[1], closeTo(0.2, 1e-6));

    finishGeneration.complete();
    await generation;
    await subscription.cancel();
    await provider.close();
  });

  test('preserves incremental ordering and sample timeline', () async {
    final worker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      infer: (request, cancellation, onAudioChunk) {
        onAudioChunk(_chunk(<double>[1, 2], frameIndex: 0, offset: 0));
        onAudioChunk(_chunk(<double>[3, 4, 5], frameIndex: 1, offset: 2));
        return const MlxTtsWorkerResult(
          sampleRate: 24000,
          sampleCount: 5,
          frameCount: 2,
        );
      },
    );
    final provider = MlxSpeechProvider(
      ttsWorker: worker,
      ttsModelId: 'pocket',
      voiceIds: const <String>['alba', 'marius'],
    );
    final session = await provider
        .synthesize(
          SpeechSynthesisRequest(
            text: 'Timeline',
            modelId: 'pocket',
            voiceId: 'marius',
            providerOptions: MlxSynthesisOptions(seed: 7, maxTokens: 10),
          ),
        )
        .prepare();
    final frames = <AudioFrame>[];
    final subscription = session.frames.listen(frames.add);

    await session.start();

    expect(frames, hasLength(2));
    expect(frames.map((frame) => frame.sequence), orderedEquals(<int>[0, 1]));
    expect(
      frames.map((frame) => frame.sampleOffset),
      orderedEquals(<int>[0, 2]),
    );
    expect(
      frames.map((frame) => frame.timestamp),
      orderedEquals(<Duration>[
        Duration.zero,
        const Duration(microseconds: 83),
      ]),
    );
    expect(
      frames.expand((frame) => frame.samples),
      orderedEquals(<double>[1, 2, 3, 4, 5]),
    );
    expect(session.status.state, AudioSessionState.finished);
    expect(session.format, AudioFormat(sampleRate: 24000, channels: 1));
    expect(provider.descriptor.capabilities, const <SpeechCapability>{
      SpeechCapability.textToSpeech,
    });
    expect(provider.descriptor.models.single.id, 'pocket');
    expect(
      provider.descriptor.voices.map((voice) => voice.id),
      orderedEquals(<String>['alba', 'marius']),
    );

    await subscription.cancel();
    await provider.close();
  });

  test('cancels active generation and rejects stale chunks', () async {
    final emittedFirst = Completer<void>();
    final cancellation = AudioCancellationController();
    final worker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      infer: (request, token, onAudioChunk) async {
        onAudioChunk(_chunk(<double>[1], frameIndex: 0, offset: 0));
        emittedFirst.complete();
        await token!.whenCancelled;
        token.throwIfCancelled();
        return const MlxTtsWorkerResult(
          sampleRate: 24000,
          sampleCount: 1,
          frameCount: 1,
        );
      },
    );
    final provider = MlxSpeechProvider(ttsWorker: worker);
    final session = await provider
        .synthesize(
          SpeechSynthesisRequest(
            text: 'Interrupt me',
            cancellation: cancellation.token,
          ),
        )
        .prepare();
    final frames = <AudioFrame>[];
    final subscription = session.frames.listen(frames.add);
    final generation = session.start();

    await emittedFirst.future;
    cancellation.cancel(const AudioCancellation(reason: 'barge_in'));

    await expectLater(generation, throwsA(isA<AudioCancelledException>()));
    expect(frames, hasLength(1));
    expect(session.status.state, AudioSessionState.aborted);
    await subscription.cancel();
    await provider.close();
  });

  test('serialized TTS worker never overlaps generation calls', () async {
    final releaseFirst = Completer<void>();
    var calls = 0;
    var active = 0;
    var maximumActive = 0;
    final worker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      infer: (request, cancellation, onAudioChunk) async {
        calls += 1;
        active += 1;
        maximumActive = active > maximumActive ? active : maximumActive;
        if (calls == 1) {
          await releaseFirst.future;
        }
        active -= 1;
        return const MlxTtsWorkerResult(
          sampleRate: 24000,
          sampleCount: 0,
          frameCount: 0,
        );
      },
    );
    const request = MlxTtsWorkerRequest(
      text: 'Serialized',
      modelId: 'pocket',
      voiceId: 'alba',
    );

    final first = worker.synthesize(request, onAudioChunk: (_) {});
    final second = worker.synthesize(request, onAudioChunk: (_) {});
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    releaseFirst.complete();
    await first;
    await second;
    expect(calls, 2);
    expect(maximumActive, 1);
    await worker.close();
  });

  test('TTS worker bounds total incremental PCM output', () async {
    final worker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      maximumOutputSamples: 2,
      infer: (request, cancellation, onAudioChunk) {
        onAudioChunk(_chunk(<double>[1, 2], frameIndex: 0, offset: 0));
        onAudioChunk(_chunk(<double>[3], frameIndex: 1, offset: 2));
        return const MlxTtsWorkerResult(
          sampleRate: 24000,
          sampleCount: 3,
          frameCount: 2,
        );
      },
    );

    await expectLater(
      worker.synthesize(
        const MlxTtsWorkerRequest(
          text: 'Bounded',
          modelId: 'pocket',
          voiceId: 'alba',
        ),
        onAudioChunk: (_) {},
      ),
      throwsA(
        isA<MlxWorkerException>().having(
          (error) => error.code,
          'code',
          'synthesis_output_limit',
        ),
      ),
    );
    await worker.close();
  });

  test('TTS isolate close terminates active startup or generation', () async {
    final modelDirectory = Directory.systemTemp.createTempSync(
      'speech_mlx_tts_close_active',
    );
    addTearDown(() => modelDirectory.deleteSync(recursive: true));
    File(
      '${modelDirectory.path}/config.json',
    ).writeAsStringSync('{"model_type":"unsupported_fixture"}');
    final worker = MlxIsolateTtsWorker(modelPath: modelDirectory.path);
    final generation = worker.synthesize(
      const MlxTtsWorkerRequest(
        text: 'Close',
        modelId: 'fixture',
        voiceId: 'alba',
      ),
      onAudioChunk: (_) {},
    );
    final expectation = expectLater(
      generation,
      throwsA(anyOf(isA<AudioCancelledException>(), isA<MlxWorkerException>())),
    );
    await Future<void>.delayed(Duration.zero);

    await worker.close().timeout(const Duration(seconds: 1));
    await expectation;
  });

  test('provider close cancels sessions and disposes worker once', () async {
    final began = Completer<void>();
    var disposeCount = 0;
    final worker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      infer: (request, cancellation, onAudioChunk) async {
        began.complete();
        await cancellation!.whenCancelled;
        cancellation.throwIfCancelled();
        return const MlxTtsWorkerResult(
          sampleRate: 24000,
          sampleCount: 0,
          frameCount: 0,
        );
      },
      dispose: () => disposeCount += 1,
    );
    final provider = MlxSpeechProvider(ttsWorker: worker);
    final source = provider.synthesize(SpeechSynthesisRequest(text: 'Cleanup'));
    final session = await source.prepare();
    final generation = session.start();
    await began.future;

    await provider.close();
    await provider.close();

    await expectLater(generation, throwsA(isA<AudioCancelledException>()));
    expect(disposeCount, 1);
    expect(session.status.state, AudioSessionState.closed);
    await expectLater(source.prepare(), throwsStateError);
  });

  test('abort wins over an overlapping graceful stop', () async {
    final worker = _GateTtsWorker();
    final provider = MlxSpeechProvider(ttsWorker: worker);
    final session = await provider
        .synthesize(SpeechSynthesisRequest(text: 'Overlap'))
        .prepare();
    final generation = session.start();
    await worker.started.future;
    final stop = session.stop();
    await Future<void>.delayed(Duration.zero);
    final failure = AudioFailure(
      code: 'interrupted',
      stage: AudioFailureStage.provider,
      message: 'Synthesis was interrupted.',
    );
    final abort = session.abort(failure: failure);
    worker.release.complete();

    await expectLater(generation, throwsA(isA<AudioCancelledException>()));
    await Future.wait<void>(<Future<void>>[stop, abort]);
    expect(session.status.state, AudioSessionState.failed);
    expect(session.status.failure, same(failure));
    await provider.close();
  });

  test('graceful stop cannot be rewritten as an abort', () async {
    final worker = _GateTtsWorker();
    final provider = MlxSpeechProvider(ttsWorker: worker);
    final session = await provider
        .synthesize(SpeechSynthesisRequest(text: 'Stop gracefully'))
        .prepare();
    final generation = session.start();
    await worker.started.future;

    final stop = session.stop();
    worker.release.complete();

    await expectLater(generation, throwsA(isA<AudioCancelledException>()));
    await stop;
    expect(session.status.state, AudioSessionState.finished);
    await provider.close();
  });

  test('paused status observer cannot hang TTS close', () async {
    final worker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      infer: (request, cancellation, onAudioChunk) => const MlxTtsWorkerResult(
        sampleRate: 24000,
        sampleCount: 0,
        frameCount: 0,
      ),
    );
    final provider = MlxSpeechProvider(ttsWorker: worker);
    final session = await provider
        .synthesize(SpeechSynthesisRequest(text: 'Close observers'))
        .prepare();
    final StreamSubscription<AudioSessionStatus> observer = session.statuses
        .listen((_) {});
    observer.pause();

    await session.close().timeout(const Duration(seconds: 1));

    expect(session.status.state, AudioSessionState.closed);
    await observer.cancel();
    await provider.close();
  });

  test('invalid worker format fails loudly without emitting audio', () async {
    final worker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      infer: (request, cancellation, onAudioChunk) {
        onAudioChunk(
          MlxTtsWorkerChunk(
            samples: Float32List.fromList(<double>[1]),
            sampleRate: 16000,
            frameIndex: 0,
            sampleOffset: 0,
          ),
        );
        return const MlxTtsWorkerResult(
          sampleRate: 16000,
          sampleCount: 1,
          frameCount: 1,
        );
      },
    );
    final provider = MlxSpeechProvider(ttsWorker: worker);
    final session = await provider
        .synthesize(SpeechSynthesisRequest(text: 'Wrong format'))
        .prepare();
    final frames = <AudioFrame>[];
    final streamErrors = <Object>[];
    final subscription = session.frames.listen(
      frames.add,
      onError: streamErrors.add,
    );

    await expectLater(
      session.start(),
      throwsA(
        isA<AudioFailure>().having(
          (failure) => failure.code,
          'code',
          'mlx_tts_chunk_format_invalid',
        ),
      ),
    );
    expect(frames, isEmpty);
    expect(streamErrors, hasLength(1));
    expect(session.status.state, AudioSessionState.failed);

    await subscription.cancel();
    await provider.close();
  });

  test('completion metadata must match every incremental frame', () async {
    final worker = SerializedMlxTtsWorker(
      outputSampleRate: 24000,
      infer: (request, cancellation, onAudioChunk) {
        onAudioChunk(_chunk(<double>[1], frameIndex: 0, offset: 0));
        return const MlxTtsWorkerResult(
          sampleRate: 24000,
          sampleCount: 1,
          frameCount: 2,
        );
      },
    );
    final provider = MlxSpeechProvider(ttsWorker: worker);
    final session = await provider
        .synthesize(SpeechSynthesisRequest(text: 'Metadata'))
        .prepare();
    final subscription = session.frames.listen((_) {}, onError: (Object _) {});

    await expectLater(
      session.start(),
      throwsA(
        isA<AudioFailure>().having(
          (failure) => failure.code,
          'code',
          'mlx_tts_result_format_invalid',
        ),
      ),
    );
    await subscription.cancel();
    await provider.close();
  });
}

final class _GateTtsWorker implements MlxTtsWorker {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _closed = false;

  @override
  int get outputSampleRate => 24000;

  @override
  Future<MlxTtsWorkerResult> synthesize(
    MlxTtsWorkerRequest request, {
    required void Function(MlxTtsWorkerChunk chunk) onAudioChunk,
    AudioCancellationToken? cancellation,
  }) async {
    started.complete();
    await release.future;
    cancellation?.throwIfCancelled();
    return const MlxTtsWorkerResult(
      sampleRate: 24000,
      sampleCount: 0,
      frameCount: 0,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    if (!release.isCompleted) {
      release.complete();
    }
  }
}

MlxTtsWorkerChunk _chunk(
  List<double> samples, {
  required int frameIndex,
  required int offset,
}) => MlxTtsWorkerChunk(
  samples: Float32List.fromList(samples),
  sampleRate: 24000,
  frameIndex: frameIndex,
  sampleOffset: offset,
);
