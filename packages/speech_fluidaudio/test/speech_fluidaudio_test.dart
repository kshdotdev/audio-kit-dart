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
    // A batch request must clear SpeechAudioGuards.minimumRecognitionDuration,
    // which is 16,000 samples at the 16 kHz the adapter converts to.
    Float32List recognizableSamples({int count = 16000}) =>
        Float32List.fromList(
          List<double>.generate(count, (index) => (index % 4 + 1) / 10),
        );

    test(
      'subscribes before source start and performs batch recognition',
      () async {
        final runtime = _FakeRuntime();
        final source = _FiniteAudioSource(
          format: mono16k,
          samples: recognizableSamples(),
        );
        final provider = FluidAudioSpeechProvider(runtime: runtime);

        final result = await provider.transcribe(
          BatchRecognitionRequest(
            audio: source,
            options: SpeechRecognitionOptions(languageTag: 'pt-BR'),
          ),
        );

        expect(source.session.hadFrameListenerWhenStarted, isTrue);
        expect(runtime.lastBatch.samples, hasLength(16000));
        expect(
          runtime.lastBatch.samples.take(4),
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

    test('carries driver token timings onto the batch segment', () async {
      final runtime = _FakeRuntime();
      final driver = _FakeBatchAsrDriver()
        ..text = 'hello there'
        ..timings = const <FluidDriverTokenTiming>[
          FluidDriverTokenTiming(
            text: 'hello',
            start: Duration(milliseconds: 120),
            end: Duration(milliseconds: 480),
            confidence: 0.91,
          ),
          FluidDriverTokenTiming(
            text: 'there',
            start: Duration(milliseconds: 500),
            end: Duration(milliseconds: 900),
            confidence: 1.4,
          ),
        ];
      runtime.nextBatch = driver;
      final source = _FiniteAudioSource(
        format: mono16k,
        samples: recognizableSamples(),
      );
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      final result = await provider.transcribe(
        BatchRecognitionRequest(audio: source),
      );

      // One whole-audio segment, now timed: cutting it into sentences belongs
      // to the batch pipeline, not to this adapter.
      expect(result.segments, hasLength(1));
      final segment = result.segments.single;
      expect(segment.start, Duration.zero);
      expect(segment.words.map((word) => word.text), <String>[
        'hello',
        'there',
      ]);
      expect(
        segment.words.first.range.start,
        const Duration(milliseconds: 120),
      );
      expect(segment.words.first.range.end, const Duration(milliseconds: 480));
      expect(segment.words.first.confidence, closeTo(0.91, 1e-6));
      // The streaming mapper clamps out-of-range confidence; the batch path
      // reuses it rather than re-deriving the rule.
      expect(segment.words.last.confidence, 1);

      await provider.close();
    });

    test('drops malformed timings instead of failing the transcript', () async {
      final runtime = _FakeRuntime();
      final driver = _FakeBatchAsrDriver()
        ..timings = const <FluidDriverTokenTiming>[
          FluidDriverTokenTiming(
            text: 'negative',
            start: Duration(milliseconds: -10),
            end: Duration(milliseconds: 200),
            confidence: 0.5,
          ),
          FluidDriverTokenTiming(
            text: 'inverted',
            start: Duration(milliseconds: 900),
            end: Duration(milliseconds: 500),
            confidence: 0.5,
          ),
          FluidDriverTokenTiming(
            text: 'good',
            start: Duration(milliseconds: 950),
            end: Duration(milliseconds: 1200),
            confidence: 0.5,
          ),
        ];
      runtime.nextBatch = driver;
      final source = _FiniteAudioSource(
        format: mono16k,
        samples: recognizableSamples(),
      );
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      final result = await provider.transcribe(
        BatchRecognitionRequest(audio: source),
      );

      expect(result.segments.single.words.map((word) => word.text), <String>[
        'good',
      ]);

      await provider.close();
    });

    test('leaves the segment untimed when the driver reports no '
        'timings', () async {
      final runtime = _FakeRuntime();
      final source = _FiniteAudioSource(
        format: mono16k,
        samples: recognizableSamples(),
      );
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      final result = await provider.transcribe(
        BatchRecognitionRequest(audio: source),
      );

      expect(result.segments.single.words, isEmpty);

      await provider.close();
    });

    test('refuses audio shorter than one second before loading a '
        'model', () async {
      final runtime = _FakeRuntime();
      final source = _FiniteAudioSource(
        format: mono16k,
        // 15,999 samples: one short of the guard, which the Swift oracle
        // enforces as 16,000 samples at 16 kHz.
        samples: recognizableSamples(count: 15999),
      );
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      await expectLater(
        provider.transcribe(BatchRecognitionRequest(audio: source)),
        throwsA(
          isA<SpeechFailure>()
              .having(
                (failure) => failure.code,
                'code',
                SpeechAudioGuards.audioTooShortCode,
              )
              .having((failure) => failure.stage, 'stage', 'recognition')
              .having(
                (failure) => failure.providerId,
                'providerId',
                'fluidaudio',
              ),
        ),
      );

      expect(runtime.batchCreateCount, 0);
      expect(source.session.closeCount, 1);
      await provider.close();
    });

    test('accepts audio at exactly the minimum duration', () async {
      final runtime = _FakeRuntime();
      final source = _FiniteAudioSource(
        format: mono16k,
        samples: recognizableSamples(),
      );
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      final result = await provider.transcribe(
        BatchRecognitionRequest(audio: source),
      );

      expect(result.text, 'batch transcript');
      expect(runtime.batchCreateCount, 1);
      await provider.close();
    });

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

    test('surfaces speaker embeddings with their space provenance', () async {
      final runtime = _FakeRuntime();
      final source = _FiniteAudioSource(
        format: mono16k,
        samples: Float32List(160),
      );
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      final result = await provider.diarize(
        BatchDiarizationRequest(audio: source),
      );

      final embedding = result.segments.single.embedding;
      expect(embedding, isNotNull);
      expect(embedding!.providerId, 'fluidaudio');
      expect(embedding.modelId, 'vbx-diarization');
      expect(embedding.dimension, 3);
      // The driver reports [3, 4, 0]; the adapter L2-normalizes to satisfy
      // SpeakerEmbedding's contract.
      expect(embedding.vector[0], closeTo(0.6, 1e-6));
      expect(embedding.vector[1], closeTo(0.8, 1e-6));
      expect(embedding.spaceId, 'fluidaudio/vbx-diarization/3');
      await provider.close();
    });

    test(
      'drops an absent or non-finite embedding instead of surfacing it',
      () async {
        final runtime = _FakeRuntime();
        runtime.nextDiarization = _FakeDiarizationDriver(
          segments: <FluidDriverSpeakerSegment>[
            const FluidDriverSpeakerSegment(
              speakerId: 'S1',
              start: Duration.zero,
              end: Duration(milliseconds: 10),
            ),
            FluidDriverSpeakerSegment(
              speakerId: 'S2',
              start: const Duration(milliseconds: 10),
              end: const Duration(milliseconds: 20),
              embedding: Float32List.fromList(<double>[]),
            ),
            FluidDriverSpeakerSegment(
              speakerId: 'S3',
              start: const Duration(milliseconds: 20),
              end: const Duration(milliseconds: 30),
              embedding: Float32List.fromList(<double>[1, double.nan]),
            ),
          ],
        );
        final source = _FiniteAudioSource(
          format: mono16k,
          samples: Float32List(160),
        );
        final provider = FluidAudioSpeechProvider(runtime: runtime);

        final result = await provider.diarize(
          BatchDiarizationRequest(audio: source),
        );

        expect(result.segments, hasLength(3));
        expect(
          result.segments.map((segment) => segment.embedding),
          everyElement(isNull),
        );
        await provider.close();
      },
    );

    test(
      'declares the diarization and embedding capabilities together',
      () async {
        final provider = FluidAudioSpeechProvider(runtime: _FakeRuntime());

        expect(
          provider.descriptor.supports(SpeechCapability.diarization),
          isTrue,
        );
        expect(
          provider.descriptor.supports(SpeechCapability.speakerEmbedding),
          isTrue,
        );
        expect(
          provider.descriptor.models
              .firstWhere((model) => model.id == 'vbx-diarization')
              .capabilities,
          containsAll(<SpeechCapability>{
            SpeechCapability.diarization,
            SpeechCapability.speakerEmbedding,
          }),
        );
        await provider.close();
      },
    );

    test('cancellation closes an in-flight batch driver', () async {
      final runtime = _FakeRuntime();
      final driver = _FakeBatchAsrDriver()..block = true;
      runtime.nextBatch = driver;
      final source = _FiniteAudioSource(
        format: mono16k,
        samples: recognizableSamples(),
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

  group('FluidAudioSpeechProvider inverse text normalization', () {
    test('declares the capability and normalizes spoken forms', () async {
      final runtime = _FakeRuntime();
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      expect(
        provider.descriptor.supports(SpeechCapability.inverseTextNormalization),
        isTrue,
      );
      expect(
        await provider.normalize('that is twenty five dollars'),
        r'that is $25',
      );
      expect(runtime.lastItn.normalized, <String>[
        'that is twenty five dollars',
      ]);

      await provider.close();
    });

    test('loads the native normalizer once and closes it', () async {
      final runtime = _FakeRuntime();
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      await provider.normalize('one');
      await provider.normalize('two');

      expect(runtime.itnCreateCount, 1);
      await provider.close();
      expect(runtime.lastItn.closeCount, 1);
    });

    test('normalizeSentences returns one result per input, in order', () async {
      final runtime = _FakeRuntime();
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      final results = await provider.normalizeSentences(<String>[
        'twenty five dollars',
        '',
        'plain',
      ]);

      expect(results, <String>[r'$25', '', 'plain']);
      // Blank input never reaches the native layer.
      expect(runtime.lastItn.normalized, <String>[
        'twenty five dollars',
        'plain',
      ]);
      expect(await provider.normalizeSentences(const <String>[]), isEmpty);

      await provider.close();
    });

    test(
      'blank text is returned unchanged without loading the model',
      () async {
        final runtime = _FakeRuntime();
        final provider = FluidAudioSpeechProvider(runtime: runtime);

        expect(await provider.normalize('   '), '   ');

        expect(runtime.itnCreateCount, 0);
        await provider.close();
      },
    );

    test('forwards custom rules to the native grammar', () async {
      final runtime = _FakeRuntime();
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      await provider.addRule(
        InverseTextNormalizationRule(spoken: 'ectos', written: 'Ectos'),
      );

      expect(runtime.lastItn.rules, <({String spoken, String written})>[
        (spoken: 'ectos', written: 'Ectos'),
      ]);
      await provider.close();
    });

    test('rejects a non-English language tag', () async {
      final runtime = _FakeRuntime();
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      await expectLater(
        provider.normalize('vinte e cinco', languageTag: 'pt-BR'),
        throwsA(
          isA<SpeechFailure>().having(
            (failure) => failure.code,
            'code',
            'fluid_language_unsupported',
          ),
        ),
      );
      expect(runtime.itnCreateCount, 0);
      // An English tag, however spelled, is accepted.
      expect(await provider.normalize('plain', languageTag: 'en-US'), 'plain');

      await provider.close();
    });

    test(
      'an unavailable native library fails and is retried, not cached',
      () async {
        final runtime = _FakeRuntime()
          ..itnCreateError = StateError('itn unavailable');
        final provider = FluidAudioSpeechProvider(runtime: runtime);

        await expectLater(
          provider.normalize('one'),
          throwsA(
            isA<SpeechFailure>().having(
              (failure) => failure.code,
              'code',
              'fluid_itn_unavailable',
            ),
          ),
        );

        // The library can appear after a model install, so the load is retried.
        expect(await provider.normalize('one'), 'one');
        expect(runtime.itnCreateCount, 2);
        await provider.close();
      },
    );

    test('wraps a native normalization failure as a speech failure', () async {
      final runtime = _FakeRuntime()
        ..nextItn = (_FakeItnDriver()..normalizeError = StateError('boom'));
      final provider = FluidAudioSpeechProvider(runtime: runtime);

      await expectLater(
        provider.normalize('one'),
        throwsA(
          isA<SpeechFailure>()
              .having((failure) => failure.code, 'code', 'fluid_itn_failed')
              .having((failure) => failure.stage, 'stage', 'normalization'),
        ),
      );
      await provider.close();
    });

    test('rejects normalization after the provider is closed', () async {
      final provider = FluidAudioSpeechProvider(runtime: _FakeRuntime());
      await provider.close();

      await expectLater(provider.normalize('one'), throwsStateError);
      await expectLater(
        provider.normalizeTranscript(SpeechTranscript(text: 'one')),
        throwsStateError,
      );
      await expectLater(
        provider.addRule(
          InverseTextNormalizationRule(spoken: 'a', written: 'b'),
        ),
        throwsStateError,
      );
    });

    group('transcript normalization', () {
      test(
        'takes the native whole-transcript path and keeps the words',
        () async {
          final runtime = _FakeRuntime();
          final provider = FluidAudioSpeechProvider(runtime: runtime);
          final transcript = _spokenTranscript();

          expect(provider, isA<TranscriptInverseTextNormalizer>());
          final normalized = await provider.normalizeTranscript(transcript);

          expect(normalized.text, r'that is $25');
          final driver = runtime.lastItn as _FakeTranscriptItnDriver;
          expect(driver.normalizedTranscripts, <String>[
            'that is twenty five dollars',
          ]);
          // Sentence-at-a-time normalization is not the path a transcript takes.
          expect(driver.normalized, isEmpty);
          expect(driver.lastTimings.map((timing) => timing.text), <String>[
            'that',
            'is',
            'twenty',
          ]);
          expect(driver.lastTimings.first.start, Duration.zero);

          // The very words that went in come back, so the detail the driver seam
          // cannot carry survives: an absent confidence stays absent instead of
          // returning as the zero the timing type had to send, and the speaker
          // label is still attached.
          expect(driver.lastTimings.first.confidence, 0);
          expect(normalized.words, hasLength(transcript.words.length));
          for (var index = 0; index < transcript.words.length; index += 1) {
            expect(
              identical(normalized.words[index], transcript.words[index]),
              isTrue,
            );
          }
          expect(normalized.words.first.confidence, isNull);
          expect(normalized.words[1].speakerId, 'speaker-1');
          expect(normalized.languageTag, 'en-US');
          expect(normalized.confidence, 0.9);

          await provider.close();
        },
      );

      test('falls back to preserved words on a string-only runtime', () async {
        final runtime = _FakeRuntime()..nextItn = _FakeItnDriver();
        final provider = FluidAudioSpeechProvider(runtime: runtime);
        final transcript = _spokenTranscript();

        final normalized = await provider.normalizeTranscript(transcript);

        expect(normalized.text, r'that is $25');
        expect(runtime.lastItn.normalized, <String>[
          'that is twenty five dollars',
        ]);
        expect(normalized.words, hasLength(transcript.words.length));
        expect(
          identical(normalized.words.first, transcript.words.first),
          isTrue,
        );

        await provider.close();
      });

      test('returns the same transcript when the rewrite is a no-op', () async {
        final runtime = _FakeRuntime();
        final provider = FluidAudioSpeechProvider(runtime: runtime);
        final transcript = SpeechTranscript(text: 'plain text');

        expect(
          identical(await provider.normalizeTranscript(transcript), transcript),
          isTrue,
        );

        await provider.close();
      });

      test('blank transcript text never loads the model', () async {
        final runtime = _FakeRuntime();
        final provider = FluidAudioSpeechProvider(runtime: runtime);
        final transcript = SpeechTranscript(text: '   ');

        expect(
          identical(await provider.normalizeTranscript(transcript), transcript),
          isTrue,
        );
        expect(runtime.itnCreateCount, 0);

        await provider.close();
      });

      test('guards on the transcript language when no tag is passed', () async {
        final runtime = _FakeRuntime();
        final provider = FluidAudioSpeechProvider(runtime: runtime);

        await expectLater(
          provider.normalizeTranscript(
            SpeechTranscript(text: 'vinte e cinco', languageTag: 'pt-BR'),
          ),
          throwsA(
            isA<SpeechFailure>().having(
              (failure) => failure.code,
              'code',
              'fluid_language_unsupported',
            ),
          ),
        );
        expect(runtime.itnCreateCount, 0);

        await provider.close();
      });

      test('wraps a native transcript failure as a speech failure', () async {
        final runtime = _FakeRuntime()
          ..nextItn = (_FakeTranscriptItnDriver()
            ..normalizeTranscriptError = StateError('boom'));
        final provider = FluidAudioSpeechProvider(runtime: runtime);

        await expectLater(
          provider.normalizeTranscript(_spokenTranscript()),
          throwsA(
            isA<SpeechFailure>()
                .having((failure) => failure.code, 'code', 'fluid_itn_failed')
                .having((failure) => failure.stage, 'stage', 'normalization'),
          ),
        );

        await provider.close();
      });
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

  test('TTS fails a synthesis that produced no audio at all', () async {
    final runtime = _FakeRuntime();
    // Kokoro's answer to over-long input: a clean stream with nothing in it.
    final tts = _FakeTtsDriver(<Float32List>[]);
    runtime.nextTts = tts;
    final provider = FluidAudioSpeechProvider(runtime: runtime);
    final source = provider.synthesize(
      SpeechSynthesisRequest(text: 'A sentence Kokoro refuses to voice.'),
    );
    final session = await source.prepare();
    // The stream fails inside `start`, so the expectation is armed before it.
    final framesFailed = expectLater(
      session.frames.toList(),
      throwsA(
        isA<SpeechFailure>()
            .having(
              (failure) => failure.code,
              'code',
              'fluid_tts_empty_synthesis',
            )
            .having((failure) => failure.stage, 'stage', 'synthesis')
            .having(
              (failure) => failure.providerId,
              'providerId',
              fluidAudioProviderId,
            ),
      ),
    );

    await session.start();

    await framesFailed;
    expect(session.status.state, AudioSessionState.failed);
    expect(session.status.failure?.code, 'fluid_tts_empty_synthesis');
    expect(tts.closeCount, 1, reason: 'the driver is released on the failure');

    await session.close();
    await provider.close();
  });

  test('empty synthesis input still finishes clean', () async {
    // The provider rejects blank text before a source exists, so this is the
    // only way to reach the carve-out — and it must stay a clean finish.
    final runtime = _FakeRuntime();
    runtime.nextTts = _FakeTtsDriver(<Float32List>[]);
    final source = FluidTtsAudioSource(
      runtime: runtime,
      text: '   ',
      voice: null,
      rate: 1,
      configuration: const FluidTtsDriverConfiguration(
        engine: FluidSynthesisEngine.kokoroEnglish,
        temperature: 0,
      ),
      ensureProviderOpen: () {},
      registerSession: (_) {},
      onSessionClosed: (_) {},
    );
    final session = await source.prepare();
    final framesFuture = session.frames.toList();

    await session.start();

    expect(await framesFuture, isEmpty);
    expect(session.status.state, AudioSessionState.finished);
    await session.close();
  });
}

/// A spoken-form transcript whose words carry detail the driver seam drops.
SpeechTranscript _spokenTranscript() => SpeechTranscript(
  text: 'that is twenty five dollars',
  languageTag: 'en-US',
  confidence: 0.9,
  words: <SpeechWord>[
    SpeechWord(
      text: 'that',
      range: SpeechTimeRange(
        start: Duration.zero,
        end: const Duration(milliseconds: 200),
      ),
    ),
    SpeechWord(
      text: 'is',
      range: SpeechTimeRange(
        start: const Duration(milliseconds: 200),
        end: const Duration(milliseconds: 320),
      ),
      confidence: 0.8,
      speakerId: 'speaker-1',
    ),
    SpeechWord(
      text: 'twenty',
      range: SpeechTimeRange(
        start: const Duration(milliseconds: 320),
        end: const Duration(milliseconds: 640),
      ),
      confidence: 0.7,
    ),
  ],
);

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
  _FakeItnDriver? nextItn;
  Object? itnCreateError;

  late FluidStreamingAsrDriverConfiguration lastStreamingConfiguration;
  late _FakeStreamingAsrDriver lastStreaming;
  late _FakeBatchAsrDriver lastBatch;
  late _FakeVadDriver lastVad;
  late _FakeEouDriver lastEou;
  late FluidDiarizationDriverConfiguration lastDiarizationConfiguration;
  late _FakeDiarizationDriver lastDiarization;
  late FluidTtsDriverConfiguration lastTtsConfiguration;
  late _FakeTtsDriver lastTts;
  late _FakeItnDriver lastItn;
  var closeCount = 0;
  var batchCreateCount = 0;
  var itnCreateCount = 0;

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
  Future<FluidItnDriver> createItn() async {
    itnCreateCount += 1;
    if (itnCreateError case final Object error) {
      itnCreateError = null;
      throw error;
    }
    lastItn = nextItn ?? _FakeTranscriptItnDriver();
    nextItn = null;
    return lastItn;
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

/// Runtime that can only rewrite strings, like an older `fluidaudio_dart`.
base class _FakeItnDriver implements FluidItnDriver {
  final List<String> normalized = <String>[];
  final List<({String spoken, String written})> rules =
      <({String spoken, String written})>[];
  Object? normalizeError;
  var closeCount = 0;

  @override
  Future<String> normalizeSentence(String text) async {
    normalized.add(text);
    if (normalizeError case final Object error) {
      throw error;
    }
    return _rewrite(text);
  }

  @override
  Future<void> addRule({
    required String spoken,
    required String written,
  }) async {
    rules.add((spoken: spoken, written: written));
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }

  static String _rewrite(String text) =>
      text.replaceAll('twenty five dollars', r'$25');
}

/// Runtime carrying the whole-transcript native call.
final class _FakeTranscriptItnDriver extends _FakeItnDriver
    implements FluidTranscriptItnDriver {
  final List<String> normalizedTranscripts = <String>[];
  List<FluidDriverTokenTiming> lastTimings = const <FluidDriverTokenTiming>[];
  Object? normalizeTranscriptError;

  @override
  Future<String> normalizeTranscript({
    required String text,
    required List<FluidDriverTokenTiming> timings,
  }) async {
    normalizedTranscripts.add(text);
    lastTimings = timings;
    if (normalizeTranscriptError case final Object error) {
      throw error;
    }
    return _FakeItnDriver._rewrite(text);
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
  String text = 'batch transcript';
  List<FluidDriverTokenTiming> timings = const <FluidDriverTokenTiming>[];

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
      text: text,
      confidence: 0.9,
      duration: const Duration(seconds: 1),
      timings: timings,
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
  _FakeDiarizationDriver({List<FluidDriverSpeakerSegment>? segments})
    : segments =
          segments ??
          <FluidDriverSpeakerSegment>[
            FluidDriverSpeakerSegment(
              speakerId: 'S1',
              start: Duration.zero,
              end: const Duration(milliseconds: 10),
              confidence: 0.8,
              // Deliberately un-normalized, as FluidAudio's VBx vectors are.
              embedding: Float32List.fromList(<double>[3, 4, 0]),
            ),
          ];

  final List<FluidDriverSpeakerSegment> segments;
  var closeCount = 0;

  @override
  Future<List<FluidDriverSpeakerSegment>> diarize(Float32List samples) async =>
      segments;

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
