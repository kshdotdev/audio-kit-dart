import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';
import 'package:http/http.dart' as http;
import 'package:speech_core/speech_core.dart';
import 'package:speech_openai_tts/speech_openai_tts.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAiTextToSpeechProvider', () {
    test('is cold and exposes decoded WAV as reusable audio frames', () async {
      final _FakeOpenAiTokenSource tokens = _FakeOpenAiTokenSource();
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport();
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: tokens,
        transport: transport,
        config: OpenAiTtsProviderConfig(
          frameDuration: const Duration(milliseconds: 20),
        ),
      );
      final Float32List expected = Float32List.fromList(
        List<double>.generate(1000, (int index) => (index % 100) / 100 - 0.5),
      );
      transport.enqueue(
        OpenAiTtsTransportResponse(
          statusCode: 200,
          body: Stream<Uint8List>.value(_wav(expected)),
          contentType: 'audio/wav',
        ),
      );

      final AudioSource source = provider.synthesize(
        SpeechSynthesisRequest(
          text: 'Hello from a caller-owned source.',
          modelId: 'gpt-4o-mini-tts',
          voiceId: 'coral',
          rate: 1.25,
          providerOptions: OpenAiTtsOptions(instructions: 'Speak warmly.'),
        ),
      );
      final AudioSourceSession session = await source.prepare();
      expect(tokens.calls, 0);
      expect(transport.requests, isEmpty);
      expect(session.status.state, AudioSessionState.prepared);

      final Future<List<AudioFrame>> frames = session.frames.toList();
      await session.start();
      final List<AudioFrame> emitted = await frames;

      expect(tokens.calls, 1);
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.modelId, 'gpt-4o-mini-tts');
      expect(transport.requests.single.voiceId, 'coral');
      expect(transport.requests.single.speed, 1.25);
      expect(transport.requests.single.instructions, 'Speak warmly.');
      expect(transport.requests.single.authorization, 'Bearer renewable-1');
      expect(
        transport.requests.single.toString(),
        isNot(contains('renewable-1')),
      );
      expect(emitted, hasLength(3));
      expect(emitted.map((AudioFrame frame) => frame.sequence), <int>[0, 1, 2]);
      expect(emitted.map((AudioFrame frame) => frame.sampleOffset), <int>[
        0,
        480,
        960,
      ]);
      expect(emitted.first.format.sampleRate, 24000);
      expect(emitted.first.sourceId, startsWith('openai-tts-'));
      final List<double> actual = emitted
          .expand((AudioFrame frame) => frame.samples)
          .toList();
      expect(actual, hasLength(expected.length));
      for (var index = 0; index < actual.length; index += 1) {
        expect(actual[index], closeTo(expected[index], 1 / 32768 + 0.00001));
      }
      expect(session.status.state, AudioSessionState.finished);

      await session.close();
      await provider.close();
      await provider.close();
    });

    test('renews credentials for each prepared source session', () async {
      final _FakeOpenAiTokenSource tokens = _FakeOpenAiTokenSource();
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
        ..enqueue(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: Stream<Uint8List>.value(
              _wav(Float32List.fromList(<double>[0.1])),
            ),
          ),
        )
        ..enqueue(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: Stream<Uint8List>.value(
              _wav(Float32List.fromList(<double>[0.2])),
            ),
          ),
        );
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: tokens,
        transport: transport,
      );
      final AudioSource source = provider.synthesize(
        SpeechSynthesisRequest(text: 'Reusable'),
      );

      for (var index = 0; index < 2; index += 1) {
        final AudioSourceSession session = await source.prepare();
        final Future<List<AudioFrame>> frames = session.frames.toList();
        await session.start();
        await frames;
        await session.close();
      }

      expect(tokens.calls, 2);
      expect(
        transport.requests.map(
          (OpenAiTtsTransportRequest request) => request.authorization,
        ),
        <String>['Bearer renewable-1', 'Bearer renewable-2'],
      );
      await provider.close();
    });

    test('decodes headerless PCM responses', () async {
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
        ..enqueue(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: Stream<Uint8List>.value(_pcm16(<double>[-1, 0, 0.5, 1])),
          ),
        );
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: _FakeOpenAiTokenSource(),
        transport: transport,
      );
      final AudioSourceSession session = await provider
          .synthesize(
            SpeechSynthesisRequest(
              text: 'PCM',
              providerOptions: OpenAiTtsOptions(
                responseFormat: OpenAiTtsResponseFormat.pcm,
              ),
            ),
          )
          .prepare();
      final Future<List<AudioFrame>> frames = session.frames.toList();

      await session.start();
      final List<double> samples = (await frames)
          .expand((AudioFrame frame) => frame.samples)
          .toList();

      expect(samples[0], -1);
      expect(samples[1], 0);
      expect(samples[2], closeTo(0.5, 0.0001));
      expect(samples[3], closeTo(1, 0.0001));
      await session.close();
      await provider.close();
    });

    test('emits the first WAV frame before response EOF', () async {
      final StreamController<Uint8List> body = StreamController<Uint8List>();
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
        ..enqueue(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: body.stream,
            contentType: 'audio/wav',
          ),
        );
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: _FakeOpenAiTokenSource(),
        transport: transport,
        config: OpenAiTtsProviderConfig(
          frameDuration: const Duration(milliseconds: 20),
        ),
      );
      final Float32List expected = Float32List.fromList(
        List<double>.generate(960, (int index) => index / 960 - 0.5),
      );
      final Uint8List wav = _wav(expected);
      final AudioSourceSession session = await provider
          .synthesize(SpeechSynthesisRequest(text: 'Stream now'))
          .prepare();
      final Completer<AudioFrame> firstFrame = Completer<AudioFrame>();
      final Completer<void> framesDone = Completer<void>();
      final List<AudioFrame> frames = <AudioFrame>[];
      final StreamSubscription<AudioFrame> subscription = session.frames.listen(
        (AudioFrame frame) {
          frames.add(frame);
          if (!firstFrame.isCompleted) {
            firstFrame.complete(frame);
          }
        },
        onError: framesDone.completeError,
        onDone: framesDone.complete,
      );

      await session.start();
      body.add(Uint8List.sublistView(wav, 0, 44 + 480 * 2));

      final AudioFrame first = await firstFrame.future.timeout(
        const Duration(seconds: 1),
      );
      expect(first.samples, hasLength(480));
      expect(session.status.state, AudioSessionState.active);
      expect(framesDone.isCompleted, isFalse);

      body
        ..add(Uint8List.sublistView(wav, 44 + 480 * 2))
        ..close();
      await framesDone.future;
      expect(frames, hasLength(2));
      expect(session.status.state, AudioSessionState.finished);

      await subscription.cancel();
      await session.close();
      await provider.close();
    });

    test('decodes fragmented RIFF chunks and odd chunk padding', () async {
      final Float32List expected = Float32List.fromList(<double>[
        -1,
        -0.25,
        0,
        0.25,
        0.75,
        1,
      ]);
      final Uint8List wav = _wavWithOddJunk(expected);
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
        ..enqueue(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: Stream<Uint8List>.fromIterable(<Uint8List>[
              for (var index = 0; index < wav.length; index += 1)
                Uint8List.sublistView(wav, index, index + 1),
            ]),
          ),
        );
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: _FakeOpenAiTokenSource(),
        transport: transport,
      );
      final AudioSourceSession session = await provider
          .synthesize(SpeechSynthesisRequest(text: 'Fragmented WAV'))
          .prepare();
      final Future<List<AudioFrame>> frames = session.frames.toList();

      await session.start();
      final List<double> actual = (await frames)
          .expand((AudioFrame frame) => frame.samples)
          .toList();

      expect(actual, hasLength(expected.length));
      for (var index = 0; index < actual.length; index += 1) {
        expect(actual[index], closeTo(expected[index], 1 / 32768 + 0.00001));
      }
      await session.close();
      await provider.close();
    });

    test('rejects WAV encoding and configured format mismatches', () async {
      final Uint8List wrongFormat = Uint8List.fromList(
        _wav(Float32List.fromList(<double>[0.1, 0.2])),
      );
      ByteData.sublistView(wrongFormat)
        ..setUint32(24, 16000, Endian.little)
        ..setUint32(28, 32000, Endian.little);

      final Uint8List wrongEncoding = Uint8List.fromList(
        _wav(Float32List.fromList(<double>[0.1, 0.2])),
      );
      ByteData.sublistView(wrongEncoding)
        ..setUint16(20, 3, Endian.little)
        ..setUint32(28, 96000, Endian.little)
        ..setUint16(32, 4, Endian.little)
        ..setUint16(34, 32, Endian.little);

      final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
        ..enqueue(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: Stream<Uint8List>.value(wrongFormat),
          ),
        )
        ..enqueue(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: Stream<Uint8List>.value(wrongEncoding),
          ),
        );
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: _FakeOpenAiTokenSource(),
        transport: transport,
      );

      for (final String expectedCode in <String>[
        'openai_audio_format_changed',
        'openai_wav_encoding_unsupported',
      ]) {
        final AudioSourceSession session = await provider
            .synthesize(SpeechSynthesisRequest(text: 'Validate WAV'))
            .prepare();
        final Future<List<AudioFrame>> frames = session.frames.toList();
        await session.start();
        await expectLater(
          frames,
          throwsA(
            isA<AudioFailure>().having(
              (AudioFailure failure) => failure.code,
              'code',
              expectedCode,
            ),
          ),
        );
        await session.close();
      }
      await provider.close();
    });

    test(
      'preserves fragmented PCM pairs and rejects a trailing byte',
      () async {
        final Uint8List pcm = _pcm16(<double>[-1, -0.5, 0, 0.5, 1]);
        final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
          ..enqueue(
            OpenAiTtsTransportResponse(
              statusCode: 200,
              body: Stream<Uint8List>.fromIterable(<Uint8List>[
                Uint8List.sublistView(pcm, 0, 1),
                Uint8List.sublistView(pcm, 1, 4),
                Uint8List.sublistView(pcm, 4, 7),
                Uint8List.sublistView(pcm, 7),
              ]),
            ),
          )
          ..enqueue(
            OpenAiTtsTransportResponse(
              statusCode: 200,
              body: Stream<Uint8List>.value(Uint8List.fromList(<int>[0, 0, 1])),
            ),
          );
        final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
          tokenSource: _FakeOpenAiTokenSource(),
          transport: transport,
        );
        final SpeechSynthesisRequest request = SpeechSynthesisRequest(
          text: 'Fragmented PCM',
          providerOptions: OpenAiTtsOptions(
            responseFormat: OpenAiTtsResponseFormat.pcm,
          ),
        );
        final AudioSourceSession healthy = await provider
            .synthesize(request)
            .prepare();
        final Future<List<AudioFrame>> healthyFrames = healthy.frames.toList();
        await healthy.start();
        final List<double> actual = (await healthyFrames)
            .expand((AudioFrame frame) => frame.samples)
            .toList();
        expect(actual, hasLength(5));
        expect(actual[0], -1);
        expect(actual[4], closeTo(1, 0.0001));
        await healthy.close();

        final AudioSourceSession truncated = await provider
            .synthesize(request)
            .prepare();
        final Future<List<AudioFrame>> truncatedFrames = truncated.frames
            .toList();
        await truncated.start();
        await expectLater(
          truncatedFrames,
          throwsA(
            isA<AudioFailure>().having(
              (AudioFailure failure) => failure.code,
              'code',
              'openai_pcm_invalid',
            ),
          ),
        );
        expect(truncated.status.state, AudioSessionState.failed);
        await truncated.close();
        await provider.close();
      },
    );

    test('cancellation aborts an in-flight transport operation', () async {
      final AudioCancellationController cancellation =
          AudioCancellationController();
      final _FakeOpenAiOperation pending = _FakeOpenAiOperation.pending();
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
        ..enqueueOperation(pending);
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: _FakeOpenAiTokenSource(),
        transport: transport,
      );
      final AudioSourceSession session = await provider
          .synthesize(
            SpeechSynthesisRequest(
              text: 'Cancel me',
              cancellation: cancellation.token,
            ),
          )
          .prepare();
      final Future<void> framesDone = session.frames.drain<void>();
      final Future<AudioSessionStatus> aborted = session.statuses.firstWhere(
        (AudioSessionStatus status) =>
            status.state == AudioSessionState.aborted,
      );
      await session.start();

      cancellation.cancel();

      expect((await aborted).state, AudioSessionState.aborted);
      await framesDone;
      expect(pending.abortCount, 1);
      await session.close();
      await provider.close();
    });

    test('abort wins a concurrent graceful stop', () async {
      final Completer<void> allowAbort = Completer<void>();
      final _FakeOpenAiOperation pending = _FakeOpenAiOperation.pending(
        abortGate: allowAbort.future,
      );
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
        ..enqueueOperation(pending);
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: _FakeOpenAiTokenSource(),
        transport: transport,
      );
      final AudioSourceSession session = await provider
          .synthesize(SpeechSynthesisRequest(text: 'Abort wins'))
          .prepare();
      final Future<void> framesDone = session.frames.drain<void>();
      await session.start();

      final Future<void> stopping = session.stop();
      await pumpEventQueue();
      final AudioFailure failure = AudioFailure(
        code: 'playback_interrupted',
        stage: AudioFailureStage.playback,
        message: 'Playback was interrupted.',
      );
      final Future<void> aborting = session.abort(failure: failure);

      expect(session.status.state, AudioSessionState.failed);
      expect(session.status.failure, same(failure));
      expect(pending.abortCount, 1);

      allowAbort.complete();
      await Future.wait<void>(<Future<void>>[stopping, aborting, framesDone]);

      expect(session.status.state, AudioSessionState.failed);
      expect(pending.abortCount, 1);
      await session.close();
      await provider.close();
    });

    test('paused status observer cannot hang source close', () async {
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: _FakeOpenAiTokenSource(),
        transport: _FakeOpenAiTransport(),
      );
      final AudioSourceSession session = await provider
          .synthesize(SpeechSynthesisRequest(text: 'Close without listening'))
          .prepare();
      final StreamSubscription<AudioSessionStatus> statusObserver = session
          .statuses
          .listen((_) {});
      statusObserver.pause();

      await session.close().timeout(const Duration(seconds: 1));

      expect(session.status.state, AudioSessionState.closed);
      await statusObserver.cancel();
      await provider.close();
    });

    test('maps HTTP errors without exposing response payloads', () async {
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
        ..enqueue(
          OpenAiTtsTransportResponse(
            statusCode: 429,
            body: Stream<Uint8List>.value(
              Uint8List.fromList('secret provider payload'.codeUnits),
            ),
          ),
        );
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: _FakeOpenAiTokenSource(),
        transport: transport,
      );
      final AudioSourceSession session = await provider
          .synthesize(SpeechSynthesisRequest(text: 'Retry later'))
          .prepare();
      final Future<List<AudioFrame>> frames = session.frames.toList();
      await session.start();

      await expectLater(
        frames,
        throwsA(
          isA<AudioFailure>()
              .having(
                (AudioFailure failure) => failure.code,
                'code',
                'openai_http_429',
              )
              .having(
                (AudioFailure failure) => failure.retryable,
                'retryable',
                isTrue,
              )
              .having(
                (AudioFailure failure) => failure.toString(),
                'safe rendering',
                isNot(contains('secret provider payload')),
              ),
        ),
      );
      expect(session.status.state, AudioSessionState.failed);
      await session.close();
      await provider.close();
    });

    test('close during token startup rejects the stale continuation', () async {
      final _DelayedOpenAiTokenSource tokens = _DelayedOpenAiTokenSource();
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport();
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: tokens,
        transport: transport,
      );
      final AudioSourceSession session = await provider
          .synthesize(SpeechSynthesisRequest(text: 'Do not resurrect'))
          .prepare();
      final Future<void> framesDone = session.frames.drain<void>();

      final Future<void> start = session.start();
      await tokens.requested.future;
      final Future<void> close = session.close();
      tokens.complete();

      await expectLater(start, throwsA(isA<AudioCancelledException>()));
      await close;
      await framesDone;
      expect(transport.requests, isEmpty);
      expect(session.status.state, AudioSessionState.closed);
      await provider.close();
    });

    test(
      'close during transport startup aborts and closes the late operation',
      () async {
        final _DelayedOpenAiTransport transport = _DelayedOpenAiTransport();
        final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
          tokenSource: _FakeOpenAiTokenSource(),
          transport: transport,
        );
        final AudioSourceSession session = await provider
            .synthesize(SpeechSynthesisRequest(text: 'Late transport'))
            .prepare();
        final Future<void> framesDone = session.frames.drain<void>();
        final Future<void> start = session.start();
        await transport.requested.future;

        final Future<void> close = session.close();
        final _FakeOpenAiOperation operation = _FakeOpenAiOperation.completed(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: const Stream<Uint8List>.empty(),
          ),
        );
        transport.complete(operation);

        await expectLater(start, throwsA(isA<AudioCancelledException>()));
        await close;
        await framesDone;
        expect(operation.abortCount, 1);
        expect(operation.closed, isTrue);
        expect(session.status.state, AudioSessionState.closed);
        await provider.close();
        expect(transport.closed, isTrue);
      },
    );

    test(
      'operation close errors fail audio but never skip stream cleanup',
      () async {
        final _FakeOpenAiOperation operation = _FakeOpenAiOperation.completed(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: Stream<Uint8List>.value(
              _wav(Float32List.fromList(<double>[0.1, 0.2])),
            ),
          ),
          closeError: StateError('operation close failed'),
        );
        final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
          ..enqueueOperation(operation);
        final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
          tokenSource: _FakeOpenAiTokenSource(),
          transport: transport,
        );
        final AudioSourceSession session = await provider
            .synthesize(SpeechSynthesisRequest(text: 'Cleanup'))
            .prepare();
        final Future<List<AudioFrame>> frames = session.frames.toList();

        await session.start();
        await expectLater(
          frames,
          throwsA(
            isA<AudioFailure>().having(
              (AudioFailure failure) => failure.code,
              'code',
              'openai_transport_cleanup_failed',
            ),
          ),
        );
        expect(session.status.state, AudioSessionState.failed);
        await expectLater(session.close(), throwsA(isA<StateError>()));
        expect(session.status.state, AudioSessionState.closed);
        await expectLater(provider.close(), throwsA(isA<StateError>()));
        expect(transport.closed, isTrue);
      },
    );

    test(
      'provider close releases every session after an earlier cleanup error',
      () async {
        final _FakeOpenAiOperation first = _FakeOpenAiOperation.completed(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: Stream<Uint8List>.value(
              _wav(Float32List.fromList(<double>[0.1])),
            ),
          ),
          closeError: StateError('first operation close failed'),
        );
        final _FakeOpenAiOperation second = _FakeOpenAiOperation.completed(
          OpenAiTtsTransportResponse(
            statusCode: 200,
            body: Stream<Uint8List>.value(
              _wav(Float32List.fromList(<double>[0.2])),
            ),
          ),
          closeError: StateError('second operation close failed'),
        );
        final _FakeOpenAiTransport transport = _FakeOpenAiTransport()
          ..enqueueOperation(first)
          ..enqueueOperation(second);
        final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
          tokenSource: _FakeOpenAiTokenSource(),
          transport: transport,
        );
        final AudioSource source = provider.synthesize(
          SpeechSynthesisRequest(text: 'Close every session'),
        );
        final AudioSourceSession firstSession = await source.prepare();
        final AudioSourceSession secondSession = await source.prepare();
        final Future<List<AudioFrame>> firstFrames = firstSession.frames
            .toList();
        final Future<List<AudioFrame>> secondFrames = secondSession.frames
            .toList();
        await firstSession.start();
        await secondSession.start();
        await expectLater(firstFrames, throwsA(isA<AudioFailure>()));
        await expectLater(secondFrames, throwsA(isA<AudioFailure>()));

        await expectLater(provider.close(), throwsA(isA<StateError>()));

        expect(firstSession.status.state, AudioSessionState.closed);
        expect(secondSession.status.state, AudioSessionState.closed);
        expect(first.closed, isTrue);
        expect(second.closed, isTrue);
        expect(transport.closed, isTrue);
      },
    );

    test('rejects unsupported pitch before allocating resources', () {
      final _FakeOpenAiTransport transport = _FakeOpenAiTransport();
      final OpenAiTextToSpeechProvider provider = OpenAiTextToSpeechProvider(
        tokenSource: _FakeOpenAiTokenSource(),
        transport: transport,
      );

      expect(
        () => provider.synthesize(
          SpeechSynthesisRequest(text: 'No pitch', pitch: 0.2),
        ),
        throwsA(
          isA<SpeechFailure>().having(
            (SpeechFailure failure) => failure.code,
            'code',
            'openai_pitch_unsupported',
          ),
        ),
      );
      expect(transport.requests, isEmpty);
    });
  });

  group('HttpOpenAiTtsTransport', () {
    test('enforces the response limit incrementally after headers', () async {
      final _TestHttpClient client = _TestHttpClient(
        response: http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1, 2],
            <int>[3, 4],
            <int>[5],
          ]),
          200,
        ),
      );
      final HttpOpenAiTtsTransport transport = HttpOpenAiTtsTransport(
        clientFactory: () => client,
      );
      final OpenAiTtsTransportOperation operation = await transport.start(
        _transportRequest(maximumResponseBytes: 4),
      );

      final OpenAiTtsTransportResponse response = await operation.response;
      await expectLater(response.body.toList(), throwsA(isA<StateError>()));

      await operation.close();
      await transport.close();
      expect(client.closeCount, 1);
    });

    test(
      'close releases every operation and preserves the first error',
      () async {
        final List<_TestHttpClient> clients = <_TestHttpClient>[
          _TestHttpClient(
            response: http.StreamedResponse(
              const Stream<List<int>>.empty(),
              200,
            ),
            closeError: StateError('first close failed'),
          ),
          _TestHttpClient(
            response: http.StreamedResponse(
              const Stream<List<int>>.empty(),
              200,
            ),
          ),
        ];
        var clientIndex = 0;
        final HttpOpenAiTtsTransport transport = HttpOpenAiTtsTransport(
          clientFactory: () => clients[clientIndex++],
        );
        await transport.start(_transportRequest());
        await transport.start(_transportRequest());

        await expectLater(transport.close(), throwsA(isA<StateError>()));

        expect(clients[0].closeCount, 1);
        expect(clients[1].closeCount, 1);
        await expectLater(transport.close(), throwsA(isA<StateError>()));
        expect(clients[0].closeCount, 1);
        expect(clients[1].closeCount, 1);
      },
    );
  });
}

Uint8List _wav(Float32List samples) {
  final AudioFormat format = AudioFormat(sampleRate: 24000, channels: 1);
  final WavEncoder encoder = WavEncoder(format: format);
  encoder.addFrame(
    AudioFrame.owned(
      format: format,
      samples: samples,
      sourceId: 'wav-source',
      trackId: 'wav-track',
      clockId: 'wav-clock',
      sequence: 0,
      sampleOffset: 0,
      timestamp: Duration.zero,
    ),
  );
  return encoder.finish();
}

Uint8List _wavWithOddJunk(Float32List samples) {
  final Uint8List canonical = _wav(samples);
  const int extraLength = 12;
  final Uint8List bytes = Uint8List(canonical.length + extraLength);
  bytes
    ..setRange(0, 12, canonical)
    ..setRange(24, bytes.length, canonical, 12);
  final ByteData data = ByteData.sublistView(bytes);
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(12, 16, 'JUNK'.codeUnits);
  data.setUint32(16, 3, Endian.little);
  bytes.setRange(20, 23, <int>[7, 8, 9]);
  bytes[23] = 0;
  return bytes;
}

Uint8List _pcm16(List<double> samples) {
  final ByteData data = ByteData(samples.length * 2);
  for (var index = 0; index < samples.length; index += 1) {
    final double value = samples[index].clamp(-1.0, 1.0);
    final int encoded = value < 0
        ? (value * 32768).round()
        : (value * 32767).round();
    data.setInt16(index * 2, encoded, Endian.little);
  }
  return data.buffer.asUint8List();
}

OpenAiTtsTransportRequest _transportRequest({
  int maximumResponseBytes = 1024,
}) => OpenAiTtsTransportRequest(
  endpoint: Uri.parse('https://example.test/v1/audio/speech'),
  authorization: 'Bearer test',
  modelId: 'tts-1',
  voiceId: 'alloy',
  text: 'Transport test',
  speed: 1,
  responseFormat: OpenAiTtsResponseFormat.pcm,
  maximumResponseBytes: maximumResponseBytes,
);

final class _FakeOpenAiTokenSource implements OpenAiTokenSource {
  int calls = 0;

  @override
  Future<OpenAiAccessToken> getToken({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    calls += 1;
    return OpenAiAccessToken(value: 'renewable-$calls');
  }
}

final class _DelayedOpenAiTokenSource implements OpenAiTokenSource {
  final Completer<void> requested = Completer<void>();
  final Completer<OpenAiAccessToken> _token = Completer<OpenAiAccessToken>();

  void complete() {
    _token.complete(const OpenAiAccessToken(value: 'late-token'));
  }

  @override
  Future<OpenAiAccessToken> getToken({
    AudioCancellationToken? cancellationToken,
  }) {
    if (!requested.isCompleted) {
      requested.complete();
    }
    // Intentionally ignores cancellation to exercise stale continuation guards.
    return _token.future;
  }
}

final class _FakeOpenAiTransport implements OpenAiTtsTransport {
  final List<OpenAiTtsTransportRequest> requests =
      <OpenAiTtsTransportRequest>[];
  final List<_FakeOpenAiOperation> _queued = <_FakeOpenAiOperation>[];
  final List<_FakeOpenAiOperation> _active = <_FakeOpenAiOperation>[];
  bool closed = false;

  void enqueue(OpenAiTtsTransportResponse response) {
    _queued.add(_FakeOpenAiOperation.completed(response));
  }

  void enqueueOperation(_FakeOpenAiOperation operation) {
    _queued.add(operation);
  }

  @override
  Future<OpenAiTtsTransportOperation> start(
    OpenAiTtsTransportRequest request, {
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    requests.add(request);
    final _FakeOpenAiOperation operation = _queued.removeAt(0);
    _active.add(operation);
    return operation;
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    await Future.wait<void>(
      _active.map((_FakeOpenAiOperation operation) => operation.close()),
    );
  }
}

final class _DelayedOpenAiTransport implements OpenAiTtsTransport {
  final Completer<OpenAiTtsTransportRequest> requested =
      Completer<OpenAiTtsTransportRequest>();
  final Completer<OpenAiTtsTransportOperation> _operation =
      Completer<OpenAiTtsTransportOperation>();
  bool closed = false;

  void complete(OpenAiTtsTransportOperation operation) {
    _operation.complete(operation);
  }

  @override
  Future<OpenAiTtsTransportOperation> start(
    OpenAiTtsTransportRequest request, {
    AudioCancellationToken? cancellationToken,
  }) {
    if (!requested.isCompleted) {
      requested.complete(request);
    }
    // Intentionally ignores cancellation to exercise late-operation cleanup.
    return _operation.future;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _FakeOpenAiOperation implements OpenAiTtsTransportOperation {
  _FakeOpenAiOperation.completed(
    OpenAiTtsTransportResponse response, {
    this.closeError,
  }) : abortGate = null {
    _response.complete(response);
  }

  _FakeOpenAiOperation.pending({this.abortGate}) : closeError = null;

  final Completer<OpenAiTtsTransportResponse> _response =
      Completer<OpenAiTtsTransportResponse>();
  final Object? closeError;
  final Future<void>? abortGate;
  Future<void>? _closeFuture;
  int abortCount = 0;
  int closeCount = 0;
  bool closed = false;

  @override
  Future<OpenAiTtsTransportResponse> get response => _response.future;

  @override
  Future<void> abort() async {
    abortCount += 1;
    await abortGate;
    if (!_response.isCompleted) {
      _response.completeError(StateError('aborted'));
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _doClose();

  Future<void> _doClose() async {
    closeCount += 1;
    closed = true;
    if (!_response.isCompleted) {
      _response.completeError(StateError('closed'));
    }
    if (closeError case final Object error) {
      throw error;
    }
  }
}

final class _TestHttpClient extends http.BaseClient {
  _TestHttpClient({required this.response, this.closeError});

  final http.StreamedResponse response;
  final Object? closeError;
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;

  @override
  void close() {
    closeCount += 1;
    if (closeError case final Object error) {
      throw error;
    }
  }
}
