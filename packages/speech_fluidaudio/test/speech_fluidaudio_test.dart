import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_core/speech_core.dart';
import 'package:speech_fluidaudio/speech_fluidaudio.dart';

void main() {
  final mono16k = AudioFormat(sampleRate: 16000, channels: 1);

  group('FluidAudioSpeechProvider streaming STT', () {
    test(
      'starts after attaching events and maps confirmation semantics',
      () async {
        final runtime = _FakeRuntime();
        final driver = _FakeStreamingAsrDriver();
        runtime.nextStreaming = driver;
        final provider = FluidAudioSpeechProvider(runtime: runtime);

        final session = await provider.prepareStreamingRecognition(
          StreamingRecognitionRequest(
            inputFormat: mono16k,
            options: SpeechRecognitionOptions(
              languageTag: 'en-US',
              vocabulary: <String>['Ectos'],
              providerOptions: FluidRecognitionOptions(
                source: FluidRecognitionSource.systemAudio,
                vocabulary: <FluidVocabularyEntry>[
                  FluidVocabularyEntry('FluidAudio', weight: 1.5),
                ],
              ),
            ),
          ),
        );
        expect(driver.started, isTrue);
        expect(driver.hadUpdateListenerWhenStarted, isTrue);
        expect(
          runtime.lastStreamingConfiguration.source,
          FluidRecognitionSource.systemAudio,
        );
        expect(
          runtime.lastStreamingConfiguration.vocabulary.map(
            (entry) => entry.text,
          ),
          <String>['FluidAudio', 'Ectos'],
        );

        final events = <SpeechRecognitionEvent>[];
        final subscription = session.results.listen(events.add);
        driver.updatesController
          ..add(
            FluidDriverTranscriptionUpdate(
              text: 'hello',
              promotesPreviousHypothesis: false,
              confidence: 0.8,
            ),
          )
          ..add(
            FluidDriverTranscriptionUpdate(
              text: 'world',
              promotesPreviousHypothesis: true,
              confidence: 0.9,
            ),
          );

        await session.write(
          _frame(mono16k, Float32List.fromList(<double>[0.1, 0.2, 0.3])),
        );
        driver.finishText = 'world';
        await session.finish();

        expect(
          driver.feeds.single,
          orderedEquals(<Matcher>[
            closeTo(0.1, 1e-6),
            closeTo(0.2, 1e-6),
            closeTo(0.3, 1e-6),
          ]),
        );
        expect(events, hasLength(4));
        expect(events[0], isA<RecognitionPartial>());
        expect((events[1] as RecognitionFinal).transcript.text, 'hello');
        expect((events[2] as RecognitionPartial).transcript.text, 'world');
        expect((events[3] as RecognitionFinal).transcript.text, 'world');
        expect(session.status.state, AudioSessionState.finished);
        expect(driver.closeCount, 1);

        await session.close();
        await subscription.cancel();
        await provider.close();
      },
    );

    test('statefully converts stereo 48 kHz input to 16 kHz mono', () async {
      final runtime = _FakeRuntime();
      final driver = _FakeStreamingAsrDriver();
      runtime.nextStreaming = driver;
      final provider = FluidAudioSpeechProvider(runtime: runtime);
      final stereo48k = AudioFormat(sampleRate: 48000, channels: 2);
      final session = await provider.prepareStreamingRecognition(
        StreamingRecognitionRequest(inputFormat: stereo48k),
      );
      final samples = Float32List(4800 * 2);
      for (var index = 0; index < samples.length; index += 2) {
        samples[index] = 1;
        samples[index + 1] = 0;
      }

      await session.write(_frame(stereo48k, samples));
      await session.finish();

      final converted = driver.feeds.expand((chunk) => chunk).toList();
      expect(converted.length, inInclusiveRange(1599, 1601));
      expect(converted, everyElement(closeTo(0.5, 1e-6)));

      await session.close();
      await provider.close();
    });

    test('paused result observers cannot hang session close', () async {
      final runtime = _FakeRuntime();
      runtime.nextStreaming = _FakeStreamingAsrDriver();
      final provider = FluidAudioSpeechProvider(runtime: runtime);
      final StreamingSpeechToTextSession session = await provider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(inputFormat: mono16k),
          );
      final StreamSubscription<SpeechRecognitionEvent> resultObserver = session
          .results
          .listen((_) {});
      final StreamSubscription<AudioSessionStatus> statusObserver = session
          .statuses
          .listen((_) {});
      resultObserver.pause();
      statusObserver.pause();

      await session.close().timeout(const Duration(seconds: 1));

      expect(session.status.state, AudioSessionState.closed);
      await resultObserver.cancel();
      await statusObserver.cancel();
      await provider.close();
    });

    test('abort cannot be overwritten by an in-flight finish', () async {
      final Completer<void> allowFinish = Completer<void>();
      final runtime = _FakeRuntime();
      final driver = _FakeStreamingAsrDriver(finishGate: allowFinish.future);
      runtime.nextStreaming = driver;
      final provider = FluidAudioSpeechProvider(runtime: runtime);
      final StreamingSpeechToTextSession session = await provider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(inputFormat: mono16k),
          );

      final Future<void> finishing = session.finish();
      await driver.finishStarted.future;
      final Future<void> aborting = session.abort();

      expect(session.status.state, AudioSessionState.aborted);

      allowFinish.complete();
      await expectLater(finishing, throwsA(isA<AudioFailure>()));
      await aborting;

      expect(session.status.state, AudioSessionState.aborted);
      expect(driver.closeCount, 1);
      await session.close();
      await provider.close();
    });

    test(
      'provider close reaches runtime after session cleanup failure',
      () async {
        final runtime = _FakeRuntime();
        final StateError closeError = StateError('driver close failed');
        final driver = _FakeStreamingAsrDriver(closeError: closeError);
        runtime.nextStreaming = driver;
        final provider = FluidAudioSpeechProvider(runtime: runtime);
        await provider.prepareStreamingRecognition(
          StreamingRecognitionRequest(inputFormat: mono16k),
        );

        await expectLater(provider.close(), throwsA(same(closeError)));

        expect(runtime.closeCount, 1);
        expect(driver.closeCount, 1);
        await driver.updatesController.close();
      },
    );
  });

  group('FluidAudioSpeechProvider VAD and EOU', () {
    test(
      'rechunks VAD into exact 4096-sample feeds and pads its tail',
      () async {
        final runtime = _FakeRuntime();
        final driver = _FakeVadDriver();
        runtime.nextVad = driver;
        final provider = FluidAudioSpeechProvider(runtime: runtime);
        final session = await provider.prepareVoiceActivityDetection(
          VoiceActivityDetectionRequest(
            inputFormat: mono16k,
            minimumSpeech: const Duration(milliseconds: 100),
            minimumSilence: const Duration(milliseconds: 200),
          ),
        );
        final events = <VoiceActivityEvent>[];
        final subscription = session.events.listen(events.add);

        final samples = Float32List(5000);
        samples.fillRange(0, samples.length, 0.25);
        await session.write(_frame(mono16k, samples));
        expect(driver.feeds, hasLength(1));
        expect(driver.feeds.single, hasLength(4096));

        driver.eventsController.add(
          const FluidDriverVadEvent(probability: 0.9, sampleIndex: 4096),
        );
        await session.finish();

        expect(driver.feeds, hasLength(2));
        expect(driver.feeds.last, hasLength(4096));
        expect(driver.feeds.last.sublist(0, 904), everyElement(0.25));
        expect(driver.feeds.last.sublist(904), everyElement(0));
        expect(events.whereType<VoiceActivityStarted>(), hasLength(1));
        expect(events.whereType<VoiceActivityProbability>(), hasLength(1));
        expect(events.whereType<VoiceActivityEnded>(), hasLength(1));

        await session.close();
        await subscription.cancel();
        await provider.close();
      },
    );

    test('emits only committed FluidAudio utterance boundaries', () async {
      final runtime = _FakeRuntime();
      final driver = _FakeEouDriver();
      runtime.nextEou = driver;
      final provider = FluidAudioSpeechProvider(runtime: runtime);
      final session = await provider.prepareEndOfUtterance(
        EndOfUtteranceRequest(inputFormat: mono16k),
      );
      final events = <EndOfUtteranceEvent>[];
      final subscription = session.events.listen(events.add);

      driver.updatesController
        ..add(
          const FluidDriverEndOfUtteranceUpdate(
            text: 'still speaking',
            isFinal: false,
          ),
        )
        ..add(
          const FluidDriverEndOfUtteranceUpdate(text: 'done', isFinal: true),
        );
      await session.write(
        _frame(mono16k, Float32List.fromList(<double>[0.1, 0.2])),
      );
      driver.finishText = 'done';
      await session.finish();

      expect(events, hasLength(1));
      expect(events.single.isFinal, isTrue);
      expect(events.single.probability, 1);

      await session.close();
      await subscription.cancel();
      await provider.close();
    });
  });

  group('FluidAudioSpeechProvider batch operations', () {
    test(
      'subscribes before source start and performs batch recognition',
      () async {
        final runtime = _FakeRuntime();
        final source = _FiniteAudioSource(
          format: mono16k,
          samples: Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4]),
        );
        final provider = FluidAudioSpeechProvider(runtime: runtime);

        final result = await provider.transcribe(
          BatchRecognitionRequest(
            audio: source,
            options: SpeechRecognitionOptions(languageTag: 'pt-BR'),
          ),
        );

        expect(source.session.hadFrameListenerWhenStarted, isTrue);
        expect(
          runtime.lastBatch.samples,
          orderedEquals(<Matcher>[
            closeTo(0.1, 1e-6),
            closeTo(0.2, 1e-6),
            closeTo(0.3, 1e-6),
            closeTo(0.4, 1e-6),
          ]),
        );
        expect(runtime.lastBatch.language, 'pt');
        expect(result.text, 'batch transcript');
        expect(result.languageTag, 'pt-BR');
        expect(result.segments, hasLength(1));
        expect(runtime.lastBatch.closeCount, 1);

        await provider.close();
      },
    );

    test('maps batch diarization without leaking driver payloads', () async {
      final runtime = _FakeRuntime();
      final source = _FiniteAudioSource(
        format: mono16k,
        samples: Float32List(160),
      );
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      final result = await provider.diarize(
        BatchDiarizationRequest(
          audio: source,
          minimumSpeakers: 1,
          maximumSpeakers: 2,
        ),
      );

      expect(result.segments, hasLength(1));
      expect(result.segments.single.speakerId, 'S1');
      expect(runtime.lastDiarizationConfiguration.minimumSpeakers, 1);
      expect(runtime.lastDiarizationConfiguration.maximumSpeakers, 2);
      await provider.close();
    });

    test('cancellation closes an in-flight batch driver', () async {
      final runtime = _FakeRuntime();
      final driver = _FakeBatchAsrDriver()..block = true;
      runtime.nextBatch = driver;
      final source = _FiniteAudioSource(
        format: mono16k,
        samples: Float32List(160),
      );
      final cancellation = AudioCancellationController();
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      final operation = provider.transcribe(
        BatchRecognitionRequest(
          audio: source,
          cancellation: cancellation.token,
        ),
      );
      await driver.transcribeStarted.future;
      cancellation.cancel(const AudioCancellation(reason: 'test'));

      await expectLater(
        operation,
        throwsA(
          isA<SpeechFailure>().having(
            (failure) => failure.code,
            'code',
            'fluid_cancelled',
          ),
        ),
      );
      expect(driver.closeCount, 1);
      await provider.close();
    });

    test('rejects batch audio before its bounded collector can grow', () async {
      final runtime = _FakeRuntime();
      final source = _FiniteAudioSource(
        format: mono16k,
        samples: Float32List.fromList(<double>[0.1, 0.2, 0.3, 0.4]),
      );
      final provider = FluidAudioSpeechProvider(
        runtime: runtime,
        maximumBatchAudioDuration: const Duration(microseconds: 125),
      );

      await expectLater(
        provider.transcribe(BatchRecognitionRequest(audio: source)),
        throwsA(
          isA<SpeechFailure>().having(
            (SpeechFailure failure) => failure.code,
            'code',
            'fluid_batch_audio_too_long',
          ),
        ),
      );

      expect(runtime.batchCreateCount, 0);
      expect(source.session.closeCount, 1);
      await provider.close();
    });
  });

  test('TTS is a finite AudioSource with deterministic metadata', () async {
    final runtime = _FakeRuntime();
    final tts = _FakeTtsDriver(<Float32List>[
      Float32List.fromList(<double>[0.1, 0.2]),
      Float32List.fromList(<double>[0.3]),
    ]);
    runtime.nextTts = tts;
    final provider = FluidAudioSpeechProvider(runtime: runtime);
    final source = provider.synthesize(
      SpeechSynthesisRequest(
        text: 'Hello',
        modelId: 'kokoro-english',
        rate: 1.2,
      ),
    );
    final session = await source.prepare();
    final framesFuture = session.frames.toList();

    await session.start();
    final frames = await framesFuture;

    expect(frames, hasLength(2));
    expect(frames[0].format.sampleRate, 24000);
    expect(frames[0].sequence, 0);
    expect(frames[0].sampleOffset, 0);
    expect(frames[1].sequence, 1);
    expect(frames[1].sampleOffset, 2);
    expect(session.status.state, AudioSessionState.finished);
    expect(tts.rate, 1.2);
    expect(tts.closeCount, 1);

    await session.close();
    await provider.close();
    await provider.close();
    expect(runtime.closeCount, 1);
  });
}

AudioFrame _frame(AudioFormat format, Float32List samples) => AudioFrame(
  format: format,
  samples: samples,
  sourceId: 'test-source',
  trackId: 'test-track',
  clockId: 'test-clock',
  sequence: 0,
  sampleOffset: 0,
  timestamp: Duration.zero,
);

final class _FakeRuntime implements FluidAudioRuntime {
  _FakeStreamingAsrDriver? nextStreaming;
  _FakeBatchAsrDriver? nextBatch;
  _FakeVadDriver? nextVad;
  _FakeEouDriver? nextEou;
  _FakeDiarizationDriver? nextDiarization;
  _FakeTtsDriver? nextTts;

  late FluidStreamingAsrDriverConfiguration lastStreamingConfiguration;
  late _FakeStreamingAsrDriver lastStreaming;
  late _FakeBatchAsrDriver lastBatch;
  late _FakeVadDriver lastVad;
  late _FakeEouDriver lastEou;
  late FluidDiarizationDriverConfiguration lastDiarizationConfiguration;
  late _FakeDiarizationDriver lastDiarization;
  late FluidTtsDriverConfiguration lastTtsConfiguration;
  late _FakeTtsDriver lastTts;
  var closeCount = 0;
  var batchCreateCount = 0;

  @override
  Future<FluidStreamingAsrDriver> createStreamingAsr(
    FluidStreamingAsrDriverConfiguration configuration,
  ) async {
    lastStreamingConfiguration = configuration;
    lastStreaming = nextStreaming ?? _FakeStreamingAsrDriver();
    nextStreaming = null;
    return lastStreaming;
  }

  @override
  Future<FluidBatchAsrDriver> createBatchAsr(
    FluidRecognitionModel model,
  ) async {
    batchCreateCount += 1;
    lastBatch = nextBatch ?? _FakeBatchAsrDriver();
    nextBatch = null;
    return lastBatch;
  }

  @override
  Future<FluidVadDriver> createVad({
    required double threshold,
    required Duration minimumSilence,
  }) async {
    lastVad = nextVad ?? _FakeVadDriver();
    nextVad = null;
    return lastVad;
  }

  @override
  Future<FluidEndOfUtteranceDriver> createEndOfUtterance({
    required FluidEndOfUtteranceChunk chunk,
    required Duration debounce,
  }) async {
    lastEou = nextEou ?? _FakeEouDriver();
    nextEou = null;
    return lastEou;
  }

  @override
  Future<FluidDiarizationDriver> createDiarizer(
    FluidDiarizationDriverConfiguration configuration,
  ) async {
    lastDiarizationConfiguration = configuration;
    lastDiarization = nextDiarization ?? _FakeDiarizationDriver();
    nextDiarization = null;
    return lastDiarization;
  }

  @override
  Future<FluidTtsDriver> createTts(
    FluidTtsDriverConfiguration configuration,
  ) async {
    lastTtsConfiguration = configuration;
    lastTts = nextTts ?? _FakeTtsDriver(const <Float32List>[]);
    nextTts = null;
    return lastTts;
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

final class _FakeStreamingAsrDriver implements FluidStreamingAsrDriver {
  _FakeStreamingAsrDriver({this.finishGate, this.closeError});

  final StreamController<FluidDriverTranscriptionUpdate> updatesController =
      StreamController<FluidDriverTranscriptionUpdate>.broadcast(sync: true);
  final Completer<void> finishStarted = Completer<void>();
  final Future<void>? finishGate;
  final Object? closeError;
  final List<Float32List> feeds = <Float32List>[];
  var started = false;
  var hadUpdateListenerWhenStarted = false;
  var finishText = '';
  var closeCount = 0;

  @override
  Stream<FluidDriverTranscriptionUpdate> get updates =>
      updatesController.stream;

  @override
  Future<void> start() async {
    started = true;
    hadUpdateListenerWhenStarted = updatesController.hasListener;
  }

  @override
  Future<void> feed(Float32List samples) async {
    feeds.add(Float32List.fromList(samples));
  }

  @override
  Future<String> finish() async {
    if (!finishStarted.isCompleted) {
      finishStarted.complete();
    }
    await finishGate;
    return finishText;
  }

  @override
  Future<void> close() async {
    closeCount += 1;
    if (closeError case final Object error) {
      throw error;
    }
    if (!updatesController.isClosed) {
      await updatesController.close();
    }
  }
}

final class _FakeBatchAsrDriver implements FluidBatchAsrDriver {
  final Completer<void> transcribeStarted = Completer<void>();
  final Completer<void> _unblock = Completer<void>();
  var block = false;
  var closeCount = 0;
  var _closed = false;
  Float32List samples = Float32List(0);
  String? language;

  @override
  Future<FluidDriverBatchAsrResult> transcribe(
    Float32List samples, {
    String? language,
  }) async {
    this.samples = Float32List.fromList(samples);
    this.language = language;
    if (!transcribeStarted.isCompleted) {
      transcribeStarted.complete();
    }
    if (block) {
      await _unblock.future;
    }
    return FluidDriverBatchAsrResult(
      text: 'batch transcript',
      confidence: 0.9,
      duration: const Duration(seconds: 1),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    closeCount += 1;
    if (!_unblock.isCompleted) {
      _unblock.complete();
    }
  }
}

final class _FakeVadDriver implements FluidVadDriver {
  final StreamController<FluidDriverVadEvent> eventsController =
      StreamController<FluidDriverVadEvent>.broadcast(sync: true);
  final List<Float32List> feeds = <Float32List>[];
  var closeCount = 0;

  @override
  Stream<FluidDriverVadEvent> get events => eventsController.stream;

  @override
  Future<void> feed(Float32List samples) async {
    feeds.add(Float32List.fromList(samples));
  }

  @override
  Future<void> close() async {
    closeCount += 1;
    if (!eventsController.isClosed) {
      await eventsController.close();
    }
  }
}

final class _FakeEouDriver implements FluidEndOfUtteranceDriver {
  final StreamController<FluidDriverEndOfUtteranceUpdate> updatesController =
      StreamController<FluidDriverEndOfUtteranceUpdate>.broadcast(sync: true);
  var finishText = '';
  var closeCount = 0;

  @override
  Stream<FluidDriverEndOfUtteranceUpdate> get updates =>
      updatesController.stream;

  @override
  Future<void> feed(Float32List samples) async {}

  @override
  Future<String> finish() async => finishText;

  @override
  Future<void> close() async {
    closeCount += 1;
    if (!updatesController.isClosed) {
      await updatesController.close();
    }
  }
}

final class _FakeDiarizationDriver implements FluidDiarizationDriver {
  var closeCount = 0;

  @override
  Future<List<FluidDriverSpeakerSegment>> diarize(Float32List samples) async =>
      const <FluidDriverSpeakerSegment>[
        FluidDriverSpeakerSegment(
          speakerId: 'S1',
          start: Duration.zero,
          end: Duration(milliseconds: 10),
          confidence: 0.8,
        ),
      ];

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

final class _FakeTtsDriver implements FluidTtsDriver {
  _FakeTtsDriver(this.chunks);

  final List<Float32List> chunks;
  var closeCount = 0;
  double? rate;

  @override
  Stream<FluidDriverTtsChunk> synthesize({
    required String text,
    required String? voice,
    required double rate,
  }) {
    this.rate = rate;
    return Stream<FluidDriverTtsChunk>.fromIterable(<FluidDriverTtsChunk>[
      for (var index = 0; index < chunks.length; index += 1)
        FluidDriverTtsChunk(samples: chunks[index], frameIndex: index),
    ]);
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

final class _FiniteAudioSource implements AudioSource {
  _FiniteAudioSource({
    required AudioFormat format,
    required Float32List samples,
  }) : session = _FiniteAudioSourceSession(format: format, samples: samples);

  final _FiniteAudioSourceSession session;

  @override
  Future<AudioSourceSession> prepare({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return session;
  }
}

final class _FiniteAudioSourceSession implements AudioSourceSession {
  _FiniteAudioSourceSession({required this.format, required this.samples}) {
    _framesController = StreamController<AudioFrame>.broadcast(
      sync: true,
      onListen: () {
        hadFrameListenerWhenStarted = true;
      },
    );
  }

  @override
  final AudioFormat format;
  final Float32List samples;
  late final StreamController<AudioFrame> _framesController;
  var hadFrameListenerWhenStarted = false;
  var closeCount = 0;
  var _status = const AudioSessionStatus(
    state: AudioSessionState.prepared,
    timestamp: Duration.zero,
  );

  @override
  String get sourceId => 'finite-source';

  @override
  String get trackId => 'finite-track';

  @override
  String get clockId => 'finite-clock';

  @override
  AudioSourceCapabilities get capabilities => AudioSourceCapabilities.pausable;

  @override
  Stream<AudioFrame> get frames => _framesController.stream;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses =>
      Stream<AudioSessionStatus>.value(_status);

  @override
  Future<void> start({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _status = const AudioSessionStatus(
      state: AudioSessionState.active,
      timestamp: Duration.zero,
    );
    if (samples.isNotEmpty) {
      _framesController.add(
        AudioFrame(
          format: format,
          samples: samples,
          sourceId: sourceId,
          trackId: trackId,
          clockId: clockId,
          sequence: 0,
          sampleOffset: 0,
          timestamp: Duration.zero,
        ),
      );
    }
    await _framesController.close();
    _status = const AudioSessionStatus(
      state: AudioSessionState.finished,
      timestamp: Duration.zero,
    );
  }

  @override
  Future<void> pause({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
  }

  @override
  Future<void> resume({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
  }

  @override
  Future<void> stop({AudioCancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
  }

  @override
  Future<void> abort({AudioFailure? failure}) async {}

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}
