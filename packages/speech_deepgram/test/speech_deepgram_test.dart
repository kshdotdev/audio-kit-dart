import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:speech_deepgram/speech_deepgram.dart';
import 'package:test/test.dart';

void main() {
  group('DeepgramSpeechToTextProvider', () {
    test('streams caller-owned PCM and maps typed transcript events', () async {
      final _FakeTokenSource tokens = _FakeTokenSource();
      final _FakeDeepgramTransport transport = _FakeDeepgramTransport();
      final _FakeDeepgramTransportFactory factory =
          _FakeDeepgramTransportFactory(transport);
      final DeepgramSpeechToTextProvider provider =
          DeepgramSpeechToTextProvider(
            tokenSource: tokens,
            transportFactory: factory,
          );
      final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);

      final StreamingSpeechToTextSession session = await provider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(
              inputFormat: format,
              options: SpeechRecognitionOptions(
                modelId: 'nova-3',
                languageTag: 'en-US',
                vocabulary: <String>['Ectos', 'Flutter'],
                providerOptions: DeepgramStreamingOptions(
                  utteranceEnd: const Duration(milliseconds: 800),
                  diarizationModel: DeepgramDiarizationModel.latest,
                ),
              ),
            ),
          );
      final Future<List<SpeechRecognitionEvent>> results = session.results
          .toList();

      await session.write(_frame(format, <double>[-1, 0, 1], sequence: 0));
      expect(transport.audio, hasLength(1));
      final ByteData encoded = ByteData.sublistView(transport.audio.single);
      expect(encoded.getInt16(0, Endian.little), -32768);
      expect(encoded.getInt16(2, Endian.little), 0);
      expect(encoded.getInt16(4, Endian.little), 32767);

      transport.emitJson(<String, Object>{
        'type': 'SpeechStarted',
        'timestamp': 0.1,
      });
      transport.emitJson(<String, Object>{
        'type': 'Results',
        'is_final': false,
        'speech_final': false,
        'start': 0.1,
        'duration': 0.4,
        'channel': <String, Object>{
          'alternatives': <Object>[
            <String, Object>{
              'transcript': 'hello',
              'confidence': 0.8,
              'words': <Object>[],
            },
          ],
        },
      });
      transport.emitJson(<String, Object>{
        'type': 'Results',
        'is_final': true,
        'speech_final': true,
        'start': 0.1,
        'duration': 0.6,
        'channel': <String, Object>{
          'alternatives': <Object>[
            <String, Object>{
              'transcript': 'Hello world.',
              'confidence': 0.98,
              'words': <Object>[
                <String, Object>{
                  'word': 'hello',
                  'punctuated_word': 'Hello',
                  'start': 0.1,
                  'end': 0.3,
                  'confidence': 0.99,
                  'speaker': 0,
                },
                <String, Object>{
                  'word': 'world',
                  'punctuated_word': 'world.',
                  'start': 0.31,
                  'end': 0.7,
                  'confidence': 0.97,
                  'speaker': 0,
                },
              ],
            },
          ],
        },
      });

      await session.finish();
      final List<SpeechRecognitionEvent> events = await results;
      expect(events.whereType<RecognitionSpeechStarted>(), hasLength(1));
      expect(events.whereType<RecognitionPartial>(), hasLength(1));
      final RecognitionFinal committed = events
          .whereType<RecognitionFinal>()
          .single;
      expect(committed.transcript.text, 'Hello world.');
      expect(committed.transcript.words, hasLength(2));
      expect(committed.transcript.words.first.speakerId, '0');
      expect(committed.segmentId, 'deepgram-1');
      expect(events.whereType<RecognitionSpeechEnded>(), hasLength(1));
      expect(session.status.state, AudioSessionState.finished);

      final DeepgramTransportRequest connection = factory.requests.single;
      expect(connection.authorization, 'Bearer renewable-1');
      expect(connection.toString(), isNot(contains('renewable-1')));
      expect(connection.uri.queryParameters['sample_rate'], '16000');
      expect(connection.uri.queryParameters['language'], 'en-US');
      expect(connection.uri.queryParametersAll['keyterm'], <String>[
        'Ectos',
        'Flutter',
      ]);
      expect(connection.uri.queryParameters['utterance_end_ms'], '800');
      expect(connection.uri.queryParameters['vad_events'], 'true');
      expect(connection.uri.queryParameters['diarize_model'], 'latest');

      await session.close();
      await provider.close();
      await provider.close();
    });

    test('serializes transport writes without overlapping them', () async {
      final _FakeDeepgramTransport transport = _FakeDeepgramTransport(
        holdWrites: true,
      );
      final DeepgramSpeechToTextProvider provider =
          DeepgramSpeechToTextProvider(
            tokenSource: _FakeTokenSource(),
            transportFactory: _FakeDeepgramTransportFactory(transport),
          );
      final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);
      final StreamingSpeechToTextSession session = await provider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(inputFormat: format),
          );
      final Future<void> first = session.write(
        _frame(format, <double>[0.1, 0.2], sequence: 0),
      );
      final Future<void> second = session.write(
        _frame(format, <double>[0.3, 0.4], sequence: 1),
      );

      await Future<void>.delayed(Duration.zero);
      expect(transport.audio, hasLength(1));
      expect(transport.maximumConcurrentWrites, 1);
      transport.releaseNextWrite();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(transport.audio, hasLength(2));
      expect(transport.maximumConcurrentWrites, 1);
      transport.releaseNextWrite();
      await second;

      await session.finish();
      await session.close();
      await provider.close();
    });

    test('paused result observers cannot hang session close', () async {
      final _FakeDeepgramTransport transport = _FakeDeepgramTransport();
      final DeepgramSpeechToTextProvider provider =
          DeepgramSpeechToTextProvider(
            tokenSource: _FakeTokenSource(),
            transportFactory: _FakeDeepgramTransportFactory(transport),
          );
      final StreamingSpeechToTextSession session = await provider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(
              inputFormat: AudioFormat(sampleRate: 16000, channels: 1),
            ),
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

    test('fails loudly when the bounded outgoing mailbox overflows', () async {
      final _FakeDeepgramTransport transport = _FakeDeepgramTransport(
        holdWrites: true,
      );
      final DeepgramSpeechToTextProvider provider =
          DeepgramSpeechToTextProvider(
            tokenSource: _FakeTokenSource(),
            transportFactory: _FakeDeepgramTransportFactory(transport),
            config: DeepgramProviderConfig(maximumQueuedAudioBytes: 8),
          );
      final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);
      final StreamingSpeechToTextSession session = await provider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(inputFormat: format),
          );
      final Future<void> first = expectLater(
        session.write(_frame(format, <double>[0.1, 0.2], sequence: 0)),
        throwsA(anything),
      );
      final Future<void> second = expectLater(
        session.write(_frame(format, <double>[0.3, 0.4], sequence: 1)),
        throwsA(anything),
      );
      final Future<void> overflow = session.write(
        _frame(format, <double>[0.5], sequence: 2),
      );

      await expectLater(
        overflow,
        throwsA(
          isA<AudioFailure>().having(
            (AudioFailure failure) => failure.code,
            'code',
            'deepgram_audio_queue_overflow',
          ),
        ),
      );
      await first;
      await second;
      expect(session.status.state, AudioSessionState.failed);
      expect(transport.abortCount, 1);

      await session.close();
      await provider.close();
    });

    test('request cancellation aborts the active provider stream', () async {
      final AudioCancellationController cancellation =
          AudioCancellationController();
      final _FakeDeepgramTransport transport = _FakeDeepgramTransport();
      final DeepgramSpeechToTextProvider provider =
          DeepgramSpeechToTextProvider(
            tokenSource: _FakeTokenSource(),
            transportFactory: _FakeDeepgramTransportFactory(transport),
          );
      final StreamingSpeechToTextSession session = await provider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(
              inputFormat: AudioFormat(sampleRate: 16000, channels: 1),
              cancellation: cancellation.token,
            ),
          );
      final Future<AudioSessionStatus> aborted = session.statuses.firstWhere(
        (AudioSessionStatus status) =>
            status.state == AudioSessionState.aborted,
      );

      cancellation.cancel();

      expect((await aborted).state, AudioSessionState.aborted);
      expect(transport.abortCount, 1);
      await session.close();
      await provider.close();
    });

    test('invalid provider responses become stable failures', () async {
      final _FakeDeepgramTransport transport = _FakeDeepgramTransport();
      final DeepgramSpeechToTextProvider provider =
          DeepgramSpeechToTextProvider(
            tokenSource: _FakeTokenSource(),
            transportFactory: _FakeDeepgramTransportFactory(transport),
          );
      final StreamingSpeechToTextSession session = await provider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(
              inputFormat: AudioFormat(sampleRate: 16000, channels: 1),
            ),
          );
      final Future<RecognitionFailed> failed = session.results
          .where((SpeechRecognitionEvent event) => event is RecognitionFailed)
          .cast<RecognitionFailed>()
          .first;

      transport.emitText('not json');

      final RecognitionFailed event = await failed;
      expect(event.failure.code, 'deepgram_response_invalid');
      expect(event.failure.safeMessage, isNot(contains('not json')));
      expect(session.status.failure?.code, 'deepgram_response_invalid');
      await session.close();
      await provider.close();
    });

    test('abort is immediate, idempotent, and wins over slow finish', () async {
      final Completer<void> finishGate = Completer<void>();
      final Completer<void> abortGate = Completer<void>();
      final _FakeDeepgramTransport transport = _FakeDeepgramTransport(
        finishGate: finishGate.future,
        abortGate: abortGate.future,
      );
      final DeepgramSpeechToTextProvider provider =
          DeepgramSpeechToTextProvider(
            tokenSource: _FakeTokenSource(),
            transportFactory: _FakeDeepgramTransportFactory(transport),
          );
      final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);
      final StreamingSpeechToTextSession session = await provider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(inputFormat: format),
          );
      await session.write(_frame(format, <double>[0.1, 0.2], sequence: 0));

      final Future<void> finishing = session.finish();
      await _waitUntil(() => transport.finishCount == 1);
      final Future<void> firstAbort = session.abort();
      final Future<void> secondAbort = session.abort();

      expect(identical(firstAbort, secondAbort), isTrue);
      expect(session.status.state, AudioSessionState.aborted);
      expect(
        () => session.write(_frame(format, <double>[0.3], sequence: 1)),
        throwsStateError,
      );
      finishGate.complete();
      await finishing;
      expect(session.status.state, AudioSessionState.aborted);
      expect(transport.finishCount, 1);
      expect(transport.abortCount, 1);

      abortGate.complete();
      await firstAbort;
      await session.close();
      await provider.close();
    });

    test('rejects discontinuous and out-of-order primary audio', () async {
      final _FakeDeepgramTransport discontinuousTransport =
          _FakeDeepgramTransport();
      final DeepgramSpeechToTextProvider discontinuousProvider =
          DeepgramSpeechToTextProvider(
            tokenSource: _FakeTokenSource(),
            transportFactory: _FakeDeepgramTransportFactory(
              discontinuousTransport,
            ),
          );
      final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);
      final StreamingSpeechToTextSession discontinuousSession =
          await discontinuousProvider.prepareStreamingRecognition(
            StreamingRecognitionRequest(inputFormat: format),
          );
      final AudioFrame discontinuous =
          _frame(format, <double>[0.1, 0.2], sequence: 0).copyWith(
            discontinuity: AudioDiscontinuity(
              reason: AudioDiscontinuityReason.droppedFrames,
              droppedFrameCount: 1,
            ),
          );

      await expectLater(
        discontinuousSession.write(discontinuous),
        throwsA(
          isA<AudioFailure>().having(
            (AudioFailure failure) => failure.code,
            'code',
            'deepgram_audio_discontinuity',
          ),
        ),
      );
      expect(discontinuousTransport.audio, isEmpty);
      await discontinuousSession.close();
      await discontinuousProvider.close();

      final _FakeDeepgramTransport orderedTransport = _FakeDeepgramTransport();
      final DeepgramSpeechToTextProvider orderedProvider =
          DeepgramSpeechToTextProvider(
            tokenSource: _FakeTokenSource(),
            transportFactory: _FakeDeepgramTransportFactory(orderedTransport),
          );
      final StreamingSpeechToTextSession orderedSession = await orderedProvider
          .prepareStreamingRecognition(
            StreamingRecognitionRequest(inputFormat: format),
          );
      await orderedSession.write(
        _frame(format, <double>[0.1, 0.2], sequence: 4, sampleOffset: 20),
      );
      await expectLater(
        orderedSession.write(
          _frame(format, <double>[0.3, 0.4], sequence: 6, sampleOffset: 22),
        ),
        throwsA(
          isA<AudioFailure>().having(
            (AudioFailure failure) => failure.code,
            'code',
            'deepgram_audio_out_of_order',
          ),
        ),
      );
      expect(orderedTransport.audio, hasLength(1));
      await orderedSession.close();
      await orderedProvider.close();
    });
  });
}

AudioFrame _frame(
  AudioFormat format,
  List<double> samples, {
  required int sequence,
  int? sampleOffset,
}) => AudioFrame.owned(
  format: format,
  samples: Float32List.fromList(samples),
  sourceId: 'test-source',
  trackId: 'test-track',
  clockId: 'test-clock',
  sequence: sequence,
  sampleOffset: sampleOffset ?? sequence * 2,
  timestamp: Duration.zero,
);

Future<void> _waitUntil(bool Function() condition) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 1)) {
      fail('Condition was not reached.');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

final class _FakeTokenSource implements DeepgramTokenSource {
  int calls = 0;

  @override
  Future<DeepgramAccessToken> getToken({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    calls += 1;
    return DeepgramAccessToken(
      value: 'renewable-$calls',
      authorizationScheme: DeepgramAuthorizationScheme.bearer,
    );
  }
}

final class _FakeDeepgramTransportFactory implements DeepgramTransportFactory {
  _FakeDeepgramTransportFactory(this.transport);

  final _FakeDeepgramTransport transport;
  final List<DeepgramTransportRequest> requests = <DeepgramTransportRequest>[];

  @override
  Future<DeepgramStreamingTransport> connect(
    DeepgramTransportRequest request,
  ) async {
    requests.add(request);
    return transport;
  }
}

final class _FakeDeepgramTransport implements DeepgramStreamingTransport {
  _FakeDeepgramTransport({
    this.holdWrites = false,
    this.finishGate,
    this.abortGate,
  });

  final bool holdWrites;
  final Future<void>? finishGate;
  final Future<void>? abortGate;
  final StreamController<DeepgramTransportEvent> _events =
      StreamController<DeepgramTransportEvent>.broadcast();
  final List<Uint8List> audio = <Uint8List>[];
  final List<Completer<void>> _writeGates = <Completer<void>>[];
  int _concurrentWrites = 0;
  int maximumConcurrentWrites = 0;
  int abortCount = 0;
  int finishCount = 0;
  bool _closed = false;

  @override
  Stream<DeepgramTransportEvent> get events => _events.stream;

  @override
  Future<void> sendAudio(Uint8List bytes) async {
    _concurrentWrites += 1;
    maximumConcurrentWrites = _concurrentWrites > maximumConcurrentWrites
        ? _concurrentWrites
        : maximumConcurrentWrites;
    audio.add(Uint8List.fromList(bytes));
    if (holdWrites) {
      final Completer<void> gate = Completer<void>();
      _writeGates.add(gate);
      await gate.future;
    }
    _concurrentWrites -= 1;
  }

  void releaseNextWrite() {
    final Completer<void> gate = _writeGates.firstWhere(
      (Completer<void> candidate) => !candidate.isCompleted,
    );
    gate.complete();
  }

  void emitJson(Map<String, Object> value) => emitText(jsonEncode(value));

  void emitText(String value) {
    if (!_events.isClosed) {
      _events.add(DeepgramTransportText(value));
    }
  }

  @override
  Future<void> finish() async {
    finishCount += 1;
    await finishGate;
    await Future<void>.delayed(Duration.zero);
    if (!_events.isClosed) {
      _events.add(const DeepgramTransportClosed(code: 1000));
    }
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> abort() async {
    abortCount += 1;
    await abortGate;
    for (final Completer<void> gate in _writeGates) {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final Completer<void> gate in _writeGates) {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
    await _events.close();
  }
}
