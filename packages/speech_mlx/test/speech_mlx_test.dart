import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:speech_mlx/speech_mlx.dart';
import 'package:test/test.dart';

void main() {
  test(
    'provider advertises batch STT and maps source PCM through the worker',
    () async {
      MlxBatchWorkerRequest? observed;
      var disposeCount = 0;
      final worker = SerializedMlxBatchWorker(
        inputSampleRate: 16000,
        infer: (request, cancellation, onProgress) {
          observed = request;
          onProgress?.call(0.5);
          return MlxBatchWorkerResult(
            text: 'hello world',
            languageTag: 'en',
            segments: const <MlxBatchWorkerSegment>[
              MlxBatchWorkerSegment(
                text: 'hello world',
                start: Duration.zero,
                end: Duration(seconds: 1),
              ),
            ],
          );
        },
        dispose: () => disposeCount++,
      );
      final provider = MlxSpeechProvider(worker: worker, modelId: 'parakeet');
      final progress = <double>[];
      final format = AudioFormat(sampleRate: 8000, channels: 2);
      final source = _FrameSource(format, <AudioFrame>[
        AudioFrame(
          format: format,
          samples: Float32List.fromList(<double>[1, 3, 2, 4]),
          sourceId: 'fixture',
          trackId: 'track',
          clockId: 'clock',
          sequence: 7,
          sampleOffset: 0,
          timestamp: Duration.zero,
        ),
      ]);

      final result = await provider.transcribe(
        BatchRecognitionRequest(
          audio: source,
          options: SpeechRecognitionOptions(
            modelId: 'parakeet',
            languageTag: 'en',
            providerOptions: const MlxRecognitionOptions(maxTokens: 32),
          ),
          onProgress: progress.add,
        ),
      );

      expect(provider.descriptor.capabilities, const <SpeechCapability>{
        SpeechCapability.batchSpeechToText,
      });
      expect(result.text, 'hello world');
      expect(result.segments.single.end, const Duration(seconds: 1));
      expect(observed, isNotNull);
      expect(observed!.sampleRate, 8000);
      expect(observed!.channels, 2);
      expect(observed!.maxTokens, 32);
      expect(observed!.samples, hasLength(4));
      expect(observed!.samples, orderedEquals(<double>[1, 3, 2, 4]));
      expect(progress, containsAllInOrder(<double>[0, 0.5, 1]));

      await provider.close();
      await provider.close();
      expect(disposeCount, 1);
    },
  );

  test('serialized worker never overlaps inference calls', () async {
    final firstGate = Completer<void>();
    var calls = 0;
    var active = 0;
    var maxActive = 0;
    final worker = SerializedMlxBatchWorker(
      inputSampleRate: 16000,
      infer: (request, cancellation, onProgress) async {
        calls++;
        active++;
        if (active > maxActive) maxActive = active;
        if (calls == 1) await firstGate.future;
        active--;
        return MlxBatchWorkerResult(text: '$calls', segments: const []);
      },
    );

    final first = worker.transcribe(_request());
    final second = worker.transcribe(_request());
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    firstGate.complete();
    expect((await first).text, '1');
    expect((await second).text, '2');
    expect(maxActive, 1);
    await worker.close();
  });

  test('batch worker rejects requests beyond its bounded queue', () async {
    final release = Completer<void>();
    final worker = SerializedMlxBatchWorker(
      inputSampleRate: 16000,
      maximumQueuedRequests: 1,
      infer: (request, cancellation, onProgress) async {
        await release.future;
        return MlxBatchWorkerResult(text: '', segments: const []);
      },
    );

    final first = worker.transcribe(_request());
    await expectLater(
      worker.transcribe(_request()),
      throwsA(
        isA<MlxWorkerException>().having(
          (error) => error.code,
          'code',
          'worker_queue_full',
        ),
      ),
    );
    release.complete();
    await first;
    await worker.close();
  });

  test('serialized worker close is bounded for noncooperative work', () async {
    final never = Completer<void>();
    var disposed = 0;
    final worker = SerializedMlxBatchWorker(
      inputSampleRate: 16000,
      closeTimeout: const Duration(milliseconds: 5),
      infer: (request, cancellation, onProgress) async {
        await never.future;
        return MlxBatchWorkerResult(text: '', segments: const []);
      },
      dispose: () => disposed += 1,
    );
    final inference = worker.transcribe(_request());
    final expectation = expectLater(
      inference,
      throwsA(isA<AudioCancelledException>()),
    );
    await Future<void>.delayed(Duration.zero);

    await worker.close().timeout(const Duration(seconds: 1));
    await expectation;
    expect(disposed, 1);
  });

  test('provider close drains noncooperative batch inference', () async {
    final began = Completer<void>();
    final never = Completer<void>();
    final worker = SerializedMlxBatchWorker(
      inputSampleRate: 16000,
      closeTimeout: const Duration(milliseconds: 5),
      infer: (request, cancellation, onProgress) async {
        began.complete();
        await never.future;
        return MlxBatchWorkerResult(text: '', segments: const []);
      },
    );
    final format = AudioFormat(sampleRate: 16000, channels: 1);
    final provider = MlxSpeechProvider(worker: worker);
    final transcription = provider.transcribe(
      BatchRecognitionRequest(
        audio: _FrameSource(format, <AudioFrame>[
          AudioFrame(
            format: format,
            samples: Float32List.fromList(<double>[0]),
            sourceId: 'fixture',
            trackId: 'track',
            clockId: 'clock',
            sequence: 0,
            sampleOffset: 0,
            timestamp: Duration.zero,
          ),
        ]),
      ),
    );
    final expectation = expectLater(
      transcription,
      throwsA(isA<AudioCancelledException>()),
    );
    await began.future;

    await provider.close().timeout(const Duration(seconds: 1));
    await expectation;
  });

  test('cancellation is observed before queued inference begins', () async {
    final cancellation = AudioCancellationController()
      ..cancel(const AudioCancellation(reason: 'superseded'));
    var called = false;
    final worker = SerializedMlxBatchWorker(
      inputSampleRate: 16000,
      infer: (request, cancellation, onProgress) {
        called = true;
        return MlxBatchWorkerResult(text: '', segments: const []);
      },
    );

    await expectLater(
      worker.transcribe(_request(), cancellation: cancellation.token),
      throwsA(isA<AudioCancelledException>()),
    );
    expect(called, isFalse);
    await worker.close();
  });

  test('isolate worker keeps the caller event loop responsive', () async {
    final modelDirectory = Directory.systemTemp.createTempSync(
      'speech_mlx_unsupported_model',
    );
    addTearDown(() => modelDirectory.deleteSync(recursive: true));
    File(
      '${modelDirectory.path}/config.json',
    ).writeAsStringSync('{"model_type":"unsupported_fixture"}');
    final worker = MlxIsolateBatchWorker(modelPath: modelDirectory.path);
    addTearDown(worker.close);
    final eventLoopTurn = Completer<void>();

    final inference = worker.transcribe(_request());
    Timer.run(eventLoopTurn.complete);

    await eventLoopTurn.future.timeout(const Duration(seconds: 1));
    await expectLater(inference, throwsA(isA<MlxWorkerException>()));
    await worker.close();
    await worker.close();
  });

  test('isolate worker close terminates active startup or inference', () async {
    final modelDirectory = Directory.systemTemp.createTempSync(
      'speech_mlx_close_active',
    );
    addTearDown(() => modelDirectory.deleteSync(recursive: true));
    File(
      '${modelDirectory.path}/config.json',
    ).writeAsStringSync('{"model_type":"unsupported_fixture"}');
    final worker = MlxIsolateBatchWorker(modelPath: modelDirectory.path);
    final inference = worker.transcribe(_request());
    final expectation = expectLater(
      inference,
      throwsA(anyOf(isA<AudioCancelledException>(), isA<MlxWorkerException>())),
    );
    await Future<void>.delayed(Duration.zero);

    await worker.close().timeout(const Duration(seconds: 1));
    await expectation;
  });

  test('discontinuous source audio fails before inference', () async {
    var called = false;
    final worker = SerializedMlxBatchWorker(
      inputSampleRate: 16000,
      infer: (request, cancellation, onProgress) {
        called = true;
        return MlxBatchWorkerResult(text: '', segments: const []);
      },
    );
    final format = AudioFormat(sampleRate: 16000, channels: 1);
    final source = _FrameSource(format, <AudioFrame>[
      AudioFrame(
        format: format,
        samples: Float32List.fromList(<double>[0]),
        sourceId: 'fixture',
        trackId: 'track',
        clockId: 'clock',
        sequence: 0,
        sampleOffset: 0,
        timestamp: Duration.zero,
        discontinuity: AudioDiscontinuity(
          reason: AudioDiscontinuityReason.droppedFrames,
        ),
      ),
    ]);
    final provider = MlxSpeechProvider(worker: worker);

    await expectLater(
      provider.transcribe(BatchRecognitionRequest(audio: source)),
      throwsA(
        isA<SpeechFailure>().having(
          (failure) => failure.code,
          'code',
          'discontinuous_audio',
        ),
      ),
    );
    expect(called, isFalse);
    await provider.close();
  });

  test('batch capture rejects source identity and timeline changes', () async {
    var called = false;
    final worker = SerializedMlxBatchWorker(
      inputSampleRate: 16000,
      infer: (request, cancellation, onProgress) {
        called = true;
        return MlxBatchWorkerResult(text: '', segments: const []);
      },
    );
    final format = AudioFormat(sampleRate: 16000, channels: 1);
    final source = _FrameSource(format, <AudioFrame>[
      AudioFrame(
        format: format,
        samples: Float32List.fromList(<double>[0]),
        sourceId: 'fixture',
        trackId: 'track',
        clockId: 'clock',
        sequence: 0,
        sampleOffset: 0,
        timestamp: Duration.zero,
      ),
      AudioFrame(
        format: format,
        samples: Float32List.fromList(<double>[0]),
        sourceId: 'fixture',
        trackId: 'wrong-track',
        clockId: 'clock',
        sequence: 1,
        sampleOffset: 2,
        timestamp: const Duration(microseconds: 200),
      ),
    ]);
    final provider = MlxSpeechProvider(worker: worker);

    await expectLater(
      provider.transcribe(BatchRecognitionRequest(audio: source)),
      throwsA(
        isA<SpeechFailure>().having(
          (failure) => failure.code,
          'code',
          'discontinuous_audio',
        ),
      ),
    );
    expect(called, isFalse);
    await provider.close();
  });

  test('batch capture fails before retaining PCM beyond its limit', () async {
    var called = false;
    final worker = SerializedMlxBatchWorker(
      inputSampleRate: 16000,
      infer: (request, cancellation, onProgress) {
        called = true;
        return MlxBatchWorkerResult(text: '', segments: const []);
      },
    );
    final format = AudioFormat(sampleRate: 16000, channels: 1);
    final provider = MlxSpeechProvider(worker: worker, maximumInputSamples: 1);
    final source = _FrameSource(format, <AudioFrame>[
      AudioFrame(
        format: format,
        samples: Float32List.fromList(<double>[0, 0]),
        sourceId: 'fixture',
        trackId: 'track',
        clockId: 'clock',
        sequence: 0,
        sampleOffset: 0,
        timestamp: Duration.zero,
      ),
    ]);

    await expectLater(
      provider.transcribe(BatchRecognitionRequest(audio: source)),
      throwsA(
        isA<SpeechFailure>().having(
          (failure) => failure.code,
          'code',
          'audio_too_large',
        ),
      ),
    );
    expect(called, isFalse);
    await provider.close();
  });
}

MlxBatchWorkerRequest _request() => MlxBatchWorkerRequest(
  samples: Float32List(1),
  sampleRate: 16000,
  modelId: 'fixture',
);

final class _FrameSource implements AudioSource {
  const _FrameSource(this.format, this.frames);

  final AudioFormat format;
  final List<AudioFrame> frames;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return _FrameSourceSession(format, frames);
  }
}

final class _FrameSourceSession implements AudioSourceSession {
  _FrameSourceSession(this.format, this._pendingFrames);

  final List<AudioFrame> _pendingFrames;
  final StreamController<AudioFrame> _frames = StreamController<AudioFrame>(
    sync: true,
  );
  late final Stream<AudioFrame> _frameStream = AudioFrameStream(
    _frames.stream,
    pauseSupported: true,
  );
  final StreamController<AudioSessionStatus> _statuses =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  AudioSessionState _state = AudioSessionState.prepared;
  bool _framesClosed = false;
  bool _closed = false;

  @override
  final AudioFormat format;

  @override
  String get sourceId => 'fixture';

  @override
  String get trackId => 'track';

  @override
  String get clockId => 'clock';

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.pausable;

  @override
  Stream<AudioFrame> get frames => _frameStream;

  @override
  AudioSessionStatus get status =>
      AudioSessionStatus(state: _state, timestamp: Duration.zero);

  @override
  Stream<AudioSessionStatus> get statuses => _statuses.stream;

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _state = AudioSessionState.active;
    _statuses.add(status);
    for (final frame in _pendingFrames) {
      _frames.add(frame);
    }
    await _closeFrames();
    _state = AudioSessionState.finished;
    _statuses.add(status);
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _state = AudioSessionState.paused;
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _state = AudioSessionState.active;
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    await _closeFrames();
    _state = AudioSessionState.finished;
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {
    await _closeFrames();
    _state = failure == null
        ? AudioSessionState.aborted
        : AudioSessionState.failed;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _closeFrames();
    _state = AudioSessionState.closed;
    await _statuses.close();
  }

  Future<void> _closeFrames() async {
    if (_framesClosed) return;
    _framesClosed = true;
    await _frames.close();
  }
}
