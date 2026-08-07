@Tags(<String>['integration'])
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_core/speech_core.dart';
import 'package:speech_sherpa/speech_sherpa.dart';

import '../support/fakes.dart';

/// Directory holding real installed models, supplied by the developer.
///
/// These tests load hundreds of megabytes of ONNX weights and run real
/// inference, so they never execute unless `SPEECH_SHERPA_MODELS` points at an
/// install root. CI stays offline and fast; a developer validating the native
/// path opts in explicitly:
///
/// ```sh
/// SPEECH_SHERPA_MODELS=~/models \
/// SPEECH_SHERPA_LIBRARY_DIR=../sherpa_onnx_macos/macos \
/// flutter test --tags integration
/// ```
const String _modelsVariable = 'SPEECH_SHERPA_MODELS';
const String _libraryVariable = 'SPEECH_SHERPA_LIBRARY_DIR';

void main() {
  final modelRoot = Platform.environment[_modelsVariable];
  final skip = modelRoot == null
      ? 'Set $_modelsVariable to a model install root to run these tests.'
      : null;

  group('real sherpa-onnx runtime', () {
    late SherpaModelRegistry registry;
    late SherpaSpeechProvider provider;

    setUp(() {
      registry = SherpaModelRegistry(root: Directory(modelRoot!));
      provider = SherpaSpeechProvider(registry: registry);
    });

    tearDown(() async {
      await provider.close();
    });

    test('binds the native library for this isolate', () {
      // A missing bind surfaces later as "Please initialize sherpa-onnx
      // first", which reads like a missing model rather than a missing symbol.
      expect(
        () => ensureSherpaBindings(Platform.environment[_libraryVariable]),
        returnsNormally,
      );
    });

    test('transcribes a spoken-word fixture', () async {
      final model = SherpaRecognitionModel.defaultModel;
      final paths = registry.resolveRecognition(model);
      expect(
        paths,
        isNotNull,
        reason: 'Install ${model.id} under $modelRoot first.',
      );

      final result = await provider.transcribe(
        BatchRecognitionRequest(audio: FakeAudioSource(_silence(16000))),
      );
      // Silence must not hallucinate words on a transducer.
      expect(result.text.trim(), isEmpty);
    });

    test('diarizes two synthetic speakers into distinct clusters', () async {
      expect(
        registry.resolveDiarization(),
        isNotNull,
        reason: 'Install the diarization models under $modelRoot first.',
      );

      final result = await provider.diarize(
        BatchDiarizationRequest(audio: FakeAudioSource(_twoTones())),
      );

      for (final segment in result.segments) {
        final embedding = segment.embedding;
        if (embedding != null) {
          expect(embedding.providerId, sherpaProviderId);
          expect(embedding.dimension, greaterThan(0));
          // The vector must arrive L2-normalized to be a cosine reference.
          final norm = math.sqrt(
            embedding.vector.fold<double>(0, (sum, v) => sum + v * v),
          );
          expect(norm, closeTo(1, 1e-3));
        }
      }
    });

    test('streams a real OnlineRecognizer without hallucinating', () async {
      const model = SherpaRecognitionModel.streamingZipformerEn;
      expect(
        registry.resolveRecognition(model),
        isNotNull,
        reason: 'Install ${model.id} under $modelRoot first.',
      );

      final format = AudioFormat(sampleRate: 16000, channels: 1);
      final session = await provider.prepareStreamingRecognition(
        StreamingRecognitionRequest(inputFormat: format),
      );
      final events = <SpeechRecognitionEvent>[];
      final subscription = session.results.listen(events.add);
      addTearDown(subscription.cancel);

      // Two seconds in 100 ms chunks, the cadence a live capture produces.
      const chunkSamples = 1600;
      final audio = _twoTones();
      for (var offset = 0; offset < audio.length; offset += chunkSamples) {
        final end = math.min(offset + chunkSamples, audio.length);
        await session.write(
          AudioFrame.owned(
            format: format,
            samples: Float32List.sublistView(audio, offset, end),
            sourceId: 'integration',
            trackId: 'integration',
            clockId: 'integration',
            sequence: offset ~/ chunkSamples,
            sampleOffset: offset,
            timestamp: Duration(
              microseconds:
                  offset * Duration.microsecondsPerSecond ~/ format.sampleRate,
            ),
          ),
        );
      }
      await session.finish();

      // Tones are not speech, so the only hard assertion is that the decode
      // loop ran to completion and invented nothing.
      expect(session.status.state, AudioSessionState.closed);
      expect(events.whereType<RecognitionFailed>(), isEmpty);
      for (final event in events) {
        switch (event) {
          case RecognitionPartial(:final transcript):
          case RecognitionFinal(:final transcript):
            expect(transcript.text.trim(), isEmpty);
          default:
            break;
        }
      }
    });

    test('detects speech in a tone burst surrounded by silence', () async {
      expect(
        registry.resolveVad(),
        isNotNull,
        reason: 'Install the Silero VAD model under $modelRoot first.',
      );

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
          samples: _twoTones(),
          sourceId: 'integration',
          trackId: 'integration',
          clockId: 'integration',
          sequence: 0,
          sampleOffset: 0,
          timestamp: Duration.zero,
        ),
      );
      await session.finish();

      expect(events, isNotEmpty);
    });
  }, skip: skip);
}

Float32List _silence(int samples) => Float32List(samples);

/// Two seconds of alternating tones, a crude stand-in for two speakers.
Float32List _twoTones() {
  const sampleRate = 16000;
  final samples = Float32List(sampleRate * 2);
  for (var i = 0; i < samples.length; i++) {
    final frequency = i < sampleRate ? 220.0 : 440.0;
    samples[i] = 0.3 * math.sin(2 * math.pi * frequency * i / sampleRate);
  }
  return samples;
}
