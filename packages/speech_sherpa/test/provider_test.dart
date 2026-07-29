import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_core/speech_core.dart';
import 'package:speech_sherpa/speech_sherpa.dart';

import 'support/fakes.dart';

void main() {
  late Directory root;
  late SherpaModelRegistry registry;
  late FakeSherpaRuntime runtime;

  setUp(() {
    root = Directory.systemTemp.createTempSync('speech_sherpa_provider');
    registry = SherpaModelRegistry(root: root);
    runtime = FakeSherpaRuntime();
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  SherpaSpeechProvider buildProvider() =>
      SherpaSpeechProvider(registry: registry, runtime: runtime);

  void installRecognition(SherpaRecognitionModel model) {
    final dir = registry.recognitionDirectory(model)
      ..createSync(recursive: true);
    File('${dir.path}/${model.encoderFile}').writeAsStringSync('encoder');
    File('${dir.path}/${model.decoderFile}').writeAsStringSync('decoder');
    File('${dir.path}/${model.tokensFile}').writeAsStringSync('tokens');
    final joiner = model.joinerFile;
    if (joiner != null) {
      File('${dir.path}/$joiner').writeAsStringSync('joiner');
    }
  }

  void installDiarization() {
    final support = registry.supportDirectory..createSync(recursive: true);
    final segmentation = File(
      '${support.path}/'
      '${SherpaArchivedFileModel.pyannoteSegmentation.modelFile}',
    );
    segmentation.parent.createSync(recursive: true);
    segmentation.writeAsStringSync('segmentation');
    File(
      '${support.path}/${SherpaFileModel.wespeakerResnet34.fileName}',
    ).writeAsStringSync('embedding');
  }

  void installVad() {
    final support = registry.supportDirectory..createSync(recursive: true);
    File(
      '${support.path}/${SherpaFileModel.sileroVad.fileName}',
    ).writeAsStringSync('vad');
  }

  Float32List tone(int samples) => Float32List.fromList(
    List<double>.generate(samples, (i) => (i % 32) / 64 - 0.25),
  );

  group('descriptor', () {
    test('declares only the capabilities this package implements', () {
      final descriptor = buildProvider().descriptor;

      expect(descriptor.id, sherpaProviderId);
      expect(descriptor.capabilities, <SpeechCapability>{
        SpeechCapability.streamingSpeechToText,
        SpeechCapability.batchSpeechToText,
        SpeechCapability.voiceActivityDetection,
        SpeechCapability.diarization,
        SpeechCapability.speakerEmbedding,
      });
      // TTS exists in sherpa but is not wired here, so it must not be
      // advertised: a declared capability is a promise.
      expect(
        descriptor.capabilities,
        isNot(contains(SpeechCapability.textToSpeech)),
      );
    });

    test('declares streaming on streaming models only', () {
      final models = <String, Set<SpeechCapability>>{
        for (final model in buildProvider().descriptor.models)
          model.id: model.capabilities,
      };

      for (final model in SherpaRecognitionModel.streamingModels) {
        expect(
          models[model.id],
          contains(SpeechCapability.streamingSpeechToText),
          reason: model.id,
        );
        // A streaming Zipformer cannot be batch-decoded by OfflineRecognizer.
        expect(
          models[model.id],
          isNot(contains(SpeechCapability.batchSpeechToText)),
          reason: model.id,
        );
      }
      for (final model in SherpaRecognitionModel.batchModels) {
        expect(
          models[model.id],
          contains(SpeechCapability.batchSpeechToText),
          reason: model.id,
        );
        expect(
          models[model.id],
          isNot(contains(SpeechCapability.streamingSpeechToText)),
          reason: model.id,
        );
      }
    });

    test('publishes the four recognition models with Parakeet v3 default', () {
      final ids = buildProvider().descriptor.models.map((m) => m.id).toList();

      expect(ids, contains(SherpaRecognitionModel.parakeetTdtV3.id));
      expect(ids, contains(SherpaRecognitionModel.parakeetTdtV2.id));
      expect(ids, contains(SherpaRecognitionModel.whisperLargeV3Turbo.id));
      expect(ids, contains(SherpaRecognitionModel.whisperBaseEn.id));
      expect(
        SherpaRecognitionModel.defaultModel.id,
        SherpaRecognitionModel.parakeetTdtV3.id,
      );
    });

    test('every model is marked local', () {
      expect(
        buildProvider().descriptor.models.every((model) => model.isLocal),
        isTrue,
      );
    });
  });

  group('transcribe', () {
    test('fails clearly when the model is not installed', () async {
      final provider = buildProvider();
      addTearDown(provider.close);

      await expectLater(
        provider.transcribe(
          BatchRecognitionRequest(audio: FakeAudioSource(tone(16000))),
        ),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_model_not_installed',
          ),
        ),
      );
    });

    test('rejects a model outside the catalog', () async {
      final provider = buildProvider();
      addTearDown(provider.close);

      await expectLater(
        provider.transcribe(
          BatchRecognitionRequest(
            audio: FakeAudioSource(tone(16000)),
            options: SpeechRecognitionOptions(modelId: 'not-a-model'),
          ),
        ),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_unknown_model',
          ),
        ),
      );
    });

    test('decodes and returns a single committed segment', () async {
      installRecognition(SherpaRecognitionModel.parakeetTdtV3);
      runtime.transcript = const SherpaDriverTranscript(
        text: '  hello there  ',
      );
      final provider = buildProvider();
      addTearDown(provider.close);

      final result = await provider.transcribe(
        BatchRecognitionRequest(audio: FakeAudioSource(tone(16000))),
      );

      expect(result.text, 'hello there');
      expect(result.segments, hasLength(1));
      expect(result.segments.single.start, Duration.zero);
      expect(result.segments.single.end, const Duration(seconds: 1));
      expect(runtime.asrDrivers.single.received.single, hasLength(16000));
    });

    test('leaves modelType routing to sherpa for transducers', () async {
      installRecognition(SherpaRecognitionModel.parakeetTdtV3);
      final provider = buildProvider();
      addTearDown(provider.close);

      await provider.transcribe(
        BatchRecognitionRequest(audio: FakeAudioSource(tone(1600))),
      );

      final configuration = runtime.asrConfigurations.single;
      expect(
        configuration.paths.model.kind,
        SherpaRecognitionModelKind.transducer,
      );
      expect(configuration.paths.joiner, isNotNull);
      // A transducer never carries a language: that is Whisper-only.
      expect(configuration.languageCode, isNull);
    });

    test('forwards a language subtag only for Whisper', () async {
      installRecognition(SherpaRecognitionModel.whisperBaseEn);
      final provider = buildProvider();
      addTearDown(provider.close);

      await provider.transcribe(
        BatchRecognitionRequest(
          audio: FakeAudioSource(tone(1600)),
          options: SpeechRecognitionOptions(
            modelId: SherpaRecognitionModel.whisperBaseEn.id,
            languageTag: 'en-US',
          ),
        ),
      );

      final configuration = runtime.asrConfigurations.single;
      expect(
        configuration.paths.model.kind,
        SherpaRecognitionModelKind.whisper,
      );
      expect(configuration.languageCode, 'en');
      expect(configuration.paths.joiner, isNull);
    });

    test('maps typed options onto the driver configuration', () async {
      installRecognition(SherpaRecognitionModel.parakeetTdtV3);
      final provider = buildProvider();
      addTearDown(provider.close);

      await provider.transcribe(
        BatchRecognitionRequest(
          audio: FakeAudioSource(tone(1600)),
          options: SpeechRecognitionOptions(
            providerOptions: SherpaRecognitionOptions(
              numThreads: 2,
              decodingMethod: 'modified_beam_search',
            ),
          ),
        ),
      );

      final configuration = runtime.asrConfigurations.single;
      expect(configuration.numThreads, 2);
      expect(configuration.decodingMethod, 'modified_beam_search');
    });

    test('rejects options belonging to another provider', () async {
      installRecognition(SherpaRecognitionModel.parakeetTdtV3);
      final provider = buildProvider();
      addTearDown(provider.close);

      await expectLater(
        provider.transcribe(
          BatchRecognitionRequest(
            audio: FakeAudioSource(tone(1600)),
            options: SpeechRecognitionOptions(
              providerOptions: _ForeignOptions(),
            ),
          ),
        ),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_invalid_options',
          ),
        ),
      );
    });

    test('reuses one recognizer across calls with the same model', () async {
      installRecognition(SherpaRecognitionModel.parakeetTdtV3);
      final provider = buildProvider();
      addTearDown(provider.close);

      await provider.transcribe(
        BatchRecognitionRequest(audio: FakeAudioSource(tone(1600))),
      );
      await provider.transcribe(
        BatchRecognitionRequest(audio: FakeAudioSource(tone(1600))),
      );

      expect(runtime.asrConfigurations, hasLength(1));
    });

    test('frees the previous recognizer when the model changes', () async {
      installRecognition(SherpaRecognitionModel.parakeetTdtV3);
      installRecognition(SherpaRecognitionModel.whisperBaseEn);
      final provider = buildProvider();
      addTearDown(provider.close);

      await provider.transcribe(
        BatchRecognitionRequest(audio: FakeAudioSource(tone(1600))),
      );
      await provider.transcribe(
        BatchRecognitionRequest(
          audio: FakeAudioSource(tone(1600)),
          options: SpeechRecognitionOptions(
            modelId: SherpaRecognitionModel.whisperBaseEn.id,
          ),
        ),
      );

      expect(runtime.asrConfigurations, hasLength(2));
      // Two resident recognizers is over a gigabyte for no benefit.
      expect(runtime.asrDrivers.first.closed, isTrue);
      expect(runtime.asrDrivers.last.closed, isFalse);
    });

    test(
      'unloadRecognizer frees weights but keeps the provider usable',
      () async {
        installRecognition(SherpaRecognitionModel.parakeetTdtV3);
        final provider = buildProvider();
        addTearDown(provider.close);

        await provider.transcribe(
          BatchRecognitionRequest(audio: FakeAudioSource(tone(1600))),
        );
        await provider.unloadRecognizer();
        expect(runtime.asrDrivers.single.closed, isTrue);

        await provider.transcribe(
          BatchRecognitionRequest(audio: FakeAudioSource(tone(1600))),
        );
        expect(runtime.asrConfigurations, hasLength(2));
      },
    );

    test('returns empty text for empty audio without decoding', () async {
      installRecognition(SherpaRecognitionModel.parakeetTdtV3);
      final provider = buildProvider();
      addTearDown(provider.close);

      final result = await provider.transcribe(
        BatchRecognitionRequest(audio: FakeAudioSource(Float32List(0))),
      );

      expect(result.text, isEmpty);
      expect(result.segments, isEmpty);
    });
  });

  group('diarize', () {
    test('fails clearly when the models are not installed', () async {
      final provider = buildProvider();
      addTearDown(provider.close);

      await expectLater(
        provider.diarize(
          BatchDiarizationRequest(audio: FakeAudioSource(tone(16000))),
        ),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_model_not_installed',
          ),
        ),
      );
    });

    test('surfaces embeddings tagged with their own space', () async {
      installDiarization();
      runtime.spans = <SherpaDriverSpeakerSpan>[
        SherpaDriverSpeakerSpan(
          speaker: 0,
          startSeconds: 0,
          endSeconds: 1.5,
          embedding: Float32List.fromList(<double>[3, 4]),
        ),
      ];
      final provider = buildProvider();
      addTearDown(provider.close);

      final result = await provider.diarize(
        BatchDiarizationRequest(audio: FakeAudioSource(tone(16000))),
      );

      final segment = result.segments.single;
      expect(segment.speakerId, 'speaker-0');
      expect(segment.range.start, Duration.zero);
      expect(segment.range.end, const Duration(milliseconds: 1500));

      final embedding = segment.embedding;
      expect(embedding, isNotNull);
      expect(embedding!.providerId, sherpaProviderId);
      expect(embedding.modelId, SherpaFileModel.wespeakerResnet34.id);
      // Normalized on the way out so a stored centroid is a cosine reference.
      expect(embedding.vector[0], closeTo(0.6, 1e-6));
      expect(embedding.vector[1], closeTo(0.8, 1e-6));
    });

    test('omits the embedding when the extractor produced none', () async {
      installDiarization();
      runtime.spans = const <SherpaDriverSpeakerSpan>[
        SherpaDriverSpeakerSpan(speaker: 1, startSeconds: 2, endSeconds: 3),
      ];
      final provider = buildProvider();
      addTearDown(provider.close);

      final result = await provider.diarize(
        BatchDiarizationRequest(audio: FakeAudioSource(tone(16000))),
      );

      expect(result.segments.single.embedding, isNull);
      expect(result.segments.single.speakerId, 'speaker-1');
    });

    test('orders segments by start time', () async {
      installDiarization();
      runtime.spans = const <SherpaDriverSpeakerSpan>[
        SherpaDriverSpeakerSpan(speaker: 1, startSeconds: 5, endSeconds: 6),
        SherpaDriverSpeakerSpan(speaker: 0, startSeconds: 0, endSeconds: 1),
      ];
      final provider = buildProvider();
      addTearDown(provider.close);

      final result = await provider.diarize(
        BatchDiarizationRequest(audio: FakeAudioSource(tone(16000))),
      );

      expect(result.segments.map((s) => s.speakerId), <String>[
        'speaker-0',
        'speaker-1',
      ]);
    });

    test('passes an exact speaker count only when bounds agree', () async {
      installDiarization();
      final provider = buildProvider();
      addTearDown(provider.close);

      await provider.diarize(
        BatchDiarizationRequest(
          audio: FakeAudioSource(tone(1600)),
          minimumSpeakers: 2,
          maximumSpeakers: 2,
        ),
      );
      expect(runtime.diarizationConfigurations.single.exactSpeakerCount, 2);
    });

    test('infers the speaker count when bounds differ', () async {
      installDiarization();
      final provider = buildProvider();
      addTearDown(provider.close);

      await provider.diarize(
        BatchDiarizationRequest(
          audio: FakeAudioSource(tone(1600)),
          minimumSpeakers: 2,
          maximumSpeakers: 4,
        ),
      );
      expect(
        runtime.diarizationConfigurations.single.exactSpeakerCount,
        isNull,
      );
    });

    test('carries the production clustering defaults', () async {
      installDiarization();
      final provider = buildProvider();
      addTearDown(provider.close);

      await provider.diarize(
        BatchDiarizationRequest(audio: FakeAudioSource(tone(1600))),
      );

      final configuration = runtime.diarizationConfigurations.single;
      expect(configuration.clusteringThreshold, 0.5);
      expect(configuration.minimumDurationOn, closeTo(0.3, 1e-9));
      expect(configuration.minimumDurationOff, closeTo(0.5, 1e-9));
      // 30 s per speaker at 16 kHz.
      expect(configuration.maximumEmbeddingSamples, 480000);
    });
  });

  group('voice activity', () {
    test('fails clearly when the Silero model is not installed', () async {
      final provider = buildProvider();
      addTearDown(provider.close);

      await expectLater(
        provider.prepareVoiceActivityDetection(
          VoiceActivityDetectionRequest(
            inputFormat: AudioFormat(sampleRate: 16000, channels: 1),
          ),
        ),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_model_not_installed',
          ),
        ),
      );
    });

    test('maps the neutral request onto Silero configuration', () async {
      installVad();
      final provider = buildProvider();
      addTearDown(provider.close);

      final session = await provider.prepareVoiceActivityDetection(
        VoiceActivityDetectionRequest(
          inputFormat: AudioFormat(sampleRate: 16000, channels: 1),
          startThreshold: 0.5,
          minimumSpeech: const Duration(milliseconds: 100),
          minimumSilence: const Duration(milliseconds: 250),
        ),
      );
      addTearDown(session.close);

      final configuration = runtime.vadConfigurations.single;
      expect(configuration.threshold, 0.5);
      expect(configuration.minimumSpeechSeconds, closeTo(0.1, 1e-9));
      expect(configuration.minimumSilenceSeconds, closeTo(0.25, 1e-9));
      expect(configuration.windowSize, 512);
    });

    test('emits start and end events for a completed span', () async {
      installVad();
      runtime.speechSpans = const <SherpaDriverSpeechSpan>[
        SherpaDriverSpeechSpan(startSample: 16000, sampleCount: 8000),
      ];
      final provider = buildProvider();
      addTearDown(provider.close);

      final session = await provider.prepareVoiceActivityDetection(
        VoiceActivityDetectionRequest(
          inputFormat: AudioFormat(sampleRate: 16000, channels: 1),
        ),
      );
      final events = <VoiceActivityEvent>[];
      final subscription = session.events.listen(events.add);
      addTearDown(subscription.cancel);

      await session.write(
        AudioFrame.owned(
          format: AudioFormat(sampleRate: 16000, channels: 1),
          samples: tone(16000),
          sourceId: 'src',
          trackId: 'track',
          clockId: 'clock',
          sequence: 0,
          sampleOffset: 0,
          timestamp: Duration.zero,
        ),
      );
      await session.finish();

      expect(events, hasLength(2));
      expect(events.first, isA<VoiceActivityStarted>());
      expect(events.first.at, const Duration(seconds: 1));
      expect(events.last, isA<VoiceActivityEnded>());
      expect(events.last.at, const Duration(milliseconds: 1500));
    });
  });

  group('streaming recognition', () {
    final format = AudioFormat(sampleRate: 16000, channels: 1);

    AudioFrame chunk(int index, {int samples = 1600}) => AudioFrame.owned(
      format: format,
      // Powers of two so the value survives float32 exactly and identifies
      // which chunk a buffer came from.
      samples: Float32List.fromList(
        List<double>.filled(samples, (index + 1) / 8),
      ),
      sourceId: 'src',
      trackId: 'track',
      clockId: 'clock',
      sequence: index,
      sampleOffset: index * samples,
      timestamp: Duration(
        microseconds: index * samples * Duration.microsecondsPerSecond ~/ 16000,
      ),
    );

    SherpaDriverStreamingUpdate update(String text, {bool endpoint = false}) =>
        SherpaDriverStreamingUpdate(
          transcript: SherpaDriverTranscript(text: text),
          isEndpoint: endpoint,
        );

    Future<StreamingSpeechToTextSession> prepare({
      AudioCancellationToken? cancellation,
      SpeechRecognitionOptions? options,
    }) async {
      installRecognition(SherpaRecognitionModel.streamingZipformerEn);
      final provider = buildProvider();
      addTearDown(provider.close);
      return provider.prepareStreamingRecognition(
        StreamingRecognitionRequest(
          inputFormat: format,
          options: options,
          cancellation: cancellation,
        ),
      );
    }

    test('fails clearly when the streaming model is not installed', () async {
      final provider = buildProvider();
      addTearDown(provider.close);

      await expectLater(
        provider.prepareStreamingRecognition(
          StreamingRecognitionRequest(inputFormat: format),
        ),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_model_not_installed',
          ),
        ),
      );
    });

    test('rejects a batch model for a streaming session', () async {
      // Parakeet is a real catalog entry, but OfflineRecognizer-only: routing
      // it here would fail inside sherpa instead of at the boundary.
      installRecognition(SherpaRecognitionModel.parakeetTdtV3);
      final provider = buildProvider();
      addTearDown(provider.close);

      await expectLater(
        provider.prepareStreamingRecognition(
          StreamingRecognitionRequest(
            inputFormat: format,
            options: SpeechRecognitionOptions(
              modelId: SherpaRecognitionModel.parakeetTdtV3.id,
            ),
          ),
        ),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_unknown_model',
          ),
        ),
      );
    });

    test('rejects provider options belonging to the batch path', () async {
      installRecognition(SherpaRecognitionModel.streamingZipformerEn);
      final provider = buildProvider();
      addTearDown(provider.close);

      await expectLater(
        provider.prepareStreamingRecognition(
          StreamingRecognitionRequest(
            inputFormat: format,
            options: SpeechRecognitionOptions(
              providerOptions: SherpaRecognitionOptions(),
            ),
          ),
        ),
        throwsA(
          isA<SpeechFailure>().having(
            (f) => f.code,
            'code',
            'sherpa_invalid_options',
          ),
        ),
      );
    });

    test('maps the neutral request onto endpointing rules', () async {
      final session = await prepare(
        options: SpeechRecognitionOptions(
          providerOptions: SherpaStreamingRecognitionOptions(
            silenceAfterSpeech: const Duration(milliseconds: 800),
            maximumUtterance: const Duration(seconds: 12),
          ),
        ),
      );
      addTearDown(session.close);

      final configuration = runtime.streamingConfigurations.single;
      expect(configuration.enableEndpoint, isTrue);
      expect(configuration.silenceBeforeSpeechSeconds, closeTo(2.4, 1e-9));
      expect(configuration.silenceAfterSpeechSeconds, closeTo(0.8, 1e-9));
      expect(configuration.maximumUtteranceSeconds, closeTo(12, 1e-9));
      expect(
        configuration.paths.model.id,
        SherpaRecognitionModel.streamingZipformerEn.id,
      );
    });

    test('emits a volatile partial only when the hypothesis changes', () async {
      runtime.streamingUpdates = <SherpaDriverStreamingUpdate>[
        update('hello'),
        update('hello'),
        update('hello there'),
      ];
      final session = await prepare();
      final events = <SpeechRecognitionEvent>[];
      final subscription = session.results.listen(events.add);
      addTearDown(subscription.cancel);

      for (var i = 0; i < 3; i++) {
        await session.write(chunk(i));
      }

      // Three chunks, two distinct hypotheses: the repeat is not republished.
      expect(events, hasLength(2));
      expect(events.every((e) => e is RecognitionPartial), isTrue);
      final partials = events.cast<RecognitionPartial>();
      expect(partials.map((p) => p.transcript.text), <String>[
        'hello',
        'hello there',
      ]);
      expect(partials.map((p) => p.revision), <int>[1, 2]);
      // 1600 samples per chunk at 16 kHz.
      expect(partials.last.at, const Duration(milliseconds: 300));
      expect(runtime.streamingDrivers.single.resetCount, isZero);
    });

    test(
      'confirms the segment and resets the decoder on an endpoint',
      () async {
        runtime.streamingUpdates = <SherpaDriverStreamingUpdate>[
          update('hello'),
          update('hello there', endpoint: true),
          update('next one'),
        ];
        final session = await prepare();
        final events = <SpeechRecognitionEvent>[];
        final subscription = session.results.listen(events.add);
        addTearDown(subscription.cancel);

        for (var i = 0; i < 3; i++) {
          await session.write(chunk(i));
        }

        expect(events, hasLength(3));
        expect(events[0], isA<RecognitionPartial>());
        final confirmed = events[1] as RecognitionFinal;
        expect(confirmed.transcript.text, 'hello there');
        expect(confirmed.segmentId, 'sherpa-1');
        // The next segment restarts the volatile hypothesis rather than
        // continuing the confirmed one.
        final resumed = events[2] as RecognitionPartial;
        expect(resumed.transcript.text, 'next one');

        final driver = runtime.streamingDrivers.single;
        expect(driver.resetCount, 1);
        // Reset lands between the endpoint chunk and the next one, so no audio
        // is decoded into the segment that was just confirmed.
        expect(driver.calls, <String>['accept', 'accept', 'reset', 'accept']);
      },
    );

    test('confirms the drained hypothesis on finish', () async {
      runtime.streamingUpdates = <SherpaDriverStreamingUpdate>[update('hello')];
      runtime.streamingFinishUpdate = update('hello world');
      final session = await prepare();
      final events = <SpeechRecognitionEvent>[];
      final subscription = session.results.listen(events.add);
      addTearDown(subscription.cancel);

      await session.write(chunk(0));
      await session.finish();

      expect(events.last, isA<RecognitionFinal>());
      expect((events.last as RecognitionFinal).transcript.text, 'hello world');
      expect(session.status.state, AudioSessionState.closed);
      expect(runtime.streamingDrivers.single.closed, isTrue);
    });

    test('falls back to the last partial when the tail is empty', () async {
      runtime.streamingUpdates = <SherpaDriverStreamingUpdate>[update('hello')];
      final session = await prepare();
      final events = <SpeechRecognitionEvent>[];
      final subscription = session.results.listen(events.add);
      addTearDown(subscription.cancel);

      await session.write(chunk(0));
      await session.finish();

      expect((events.last as RecognitionFinal).transcript.text, 'hello');
    });

    test(
      'emits nothing final when the endpoint already closed the tail',
      () async {
        runtime.streamingUpdates = <SherpaDriverStreamingUpdate>[
          update('hello', endpoint: true),
        ];
        final session = await prepare();
        final events = <SpeechRecognitionEvent>[];
        final subscription = session.results.listen(events.add);
        addTearDown(subscription.cancel);

        await session.write(chunk(0));
        await session.finish();

        // One confirmation, not two: finish must not re-confirm a closed
        // segment just because it has text in hand.
        expect(events.whereType<RecognitionFinal>(), hasLength(1));
        expect(
          events.whereType<RecognitionFinal>().single.segmentId,
          'sherpa-1',
        );
      },
    );

    test('decodes chunks in write order under concurrent writes', () async {
      runtime.streamingUpdates = <SherpaDriverStreamingUpdate>[
        update('one'),
        update('one two'),
        update('one two three'),
      ];
      // Descending delays: an implementation that let accepts overlap would
      // resolve the third chunk first.
      runtime.streamingAcceptDelays = const <Duration>[
        Duration(milliseconds: 30),
        Duration(milliseconds: 15),
        Duration.zero,
      ];
      final session = await prepare();
      final events = <SpeechRecognitionEvent>[];
      final subscription = session.results.listen(events.add);
      addTearDown(subscription.cancel);

      await Future.wait(<Future<void>>[
        for (var i = 0; i < 3; i++) session.write(chunk(i)),
      ]);

      final driver = runtime.streamingDrivers.single;
      expect(driver.received.map((s) => s.first), <double>[0.125, 0.25, 0.375]);
      expect(
        events.cast<RecognitionPartial>().map((p) => p.transcript.text),
        <String>['one', 'one two', 'one two three'],
      );
    });

    test('cancellation mid-stream aborts and releases the driver', () async {
      runtime.streamingUpdates = <SherpaDriverStreamingUpdate>[update('hello')];
      final cancellation = AudioCancellationController();
      final session = await prepare(cancellation: cancellation.token);
      final events = <SpeechRecognitionEvent>[];
      final subscription = session.results.listen(events.add);
      addTearDown(subscription.cancel);

      await session.write(chunk(0));
      cancellation.cancel(const AudioCancellation(reason: 'test'));
      await Future<void>.delayed(Duration.zero);

      expect(session.status.state, AudioSessionState.closed);
      expect(session.status.failure, isNull);
      expect(runtime.streamingDrivers.single.closed, isTrue);
      // The partial observed before cancellation stands; nothing is confirmed.
      expect(events.whereType<RecognitionPartial>(), hasLength(1));
      expect(events.whereType<RecognitionFinal>(), isEmpty);
      expect(() => session.write(chunk(1)), throwsStateError);
    });

    test('surfaces a decode failure and aborts the session', () async {
      final session = await prepare();
      final events = <SpeechRecognitionEvent>[];
      final subscription = session.results.listen(events.add);
      addTearDown(subscription.cancel);
      runtime.streamingDrivers.single.acceptError = StateError('boom');

      await expectLater(session.write(chunk(0)), throwsA(isA<StateError>()));

      expect(events.single, isA<RecognitionFailed>());
      expect(
        (events.single as RecognitionFailed).failure.code,
        'sherpa_streaming_failed',
      );
      expect(session.status.state, AudioSessionState.closed);
      expect(runtime.streamingDrivers.single.closed, isTrue);
    });

    test('stamps the model language on every transcript', () async {
      runtime.streamingUpdates = <SherpaDriverStreamingUpdate>[
        update('hello', endpoint: true),
      ];
      final session = await prepare();
      final events = <SpeechRecognitionEvent>[];
      final subscription = session.results.listen(events.add);
      addTearDown(subscription.cancel);

      await session.write(chunk(0));

      expect((events.single as RecognitionFinal).transcript.languageTag, 'en');
    });
  });

  group('close', () {
    test('releases sessions, drivers, and the runtime', () async {
      installRecognition(SherpaRecognitionModel.parakeetTdtV3);
      installVad();
      final provider = buildProvider();

      await provider.transcribe(
        BatchRecognitionRequest(audio: FakeAudioSource(tone(1600))),
      );
      final session = await provider.prepareVoiceActivityDetection(
        VoiceActivityDetectionRequest(
          inputFormat: AudioFormat(sampleRate: 16000, channels: 1),
        ),
      );

      await provider.close();

      expect(runtime.asrDrivers.single.closed, isTrue);
      expect(runtime.closed, isTrue);
      expect(session.status.state, AudioSessionState.closed);
    });

    test('is idempotent and blocks later work', () async {
      final provider = buildProvider();
      await provider.close();
      await provider.close();

      expect(
        () => provider.transcribe(
          BatchRecognitionRequest(audio: FakeAudioSource(tone(1600))),
        ),
        throwsStateError,
      );
    });
  });
}

final class _ForeignOptions implements SpeechProviderOptions {
  @override
  String get providerId => 'someone-else';
}
