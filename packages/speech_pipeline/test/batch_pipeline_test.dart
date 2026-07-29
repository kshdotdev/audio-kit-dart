import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

final AudioFormat _format = AudioFormat(sampleRate: 16000, channels: 1);

Float32List _chunk(double amplitude, {int sampleCount = 1600}) {
  final samples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = amplitude * math.sin(2 * math.pi * 220 * i / 16000);
  }
  return samples;
}

Stream<AudioFrame> _speechFrames(int count) {
  var sequence = 0;
  var offset = 0;
  return Stream<AudioFrame>.fromIterable(<AudioFrame>[
    for (var i = 0; i < count; i++)
      () {
        final frame = AudioFrame.owned(
          format: _format,
          samples: _chunk(0.3),
          sourceId: 'test.source',
          trackId: 'me',
          clockId: 'test.clock',
          sequence: sequence++,
          sampleOffset: offset,
          timestamp: _format.durationForFrames(offset),
        );
        offset += 1600;
        return frame;
      }(),
  ]);
}

/// A batch provider that returns scripted text, optionally with a delay so
/// out-of-order completion can be provoked.
final class _ScriptedProvider extends IdempotentSpeechProvider
    implements BatchSpeechToTextProvider {
  _ScriptedProvider(this._texts, {this.delays = const <Duration>[]});

  final List<String> _texts;
  final List<Duration> delays;
  int _call = 0;
  int get callCount => _call;

  @override
  SpeechProviderDescriptor get descriptor => SpeechProviderDescriptor(
    id: 'scripted',
    displayName: 'Scripted',
    capabilities: const <SpeechCapability>{SpeechCapability.batchSpeechToText},
  );

  @override
  Future<BatchRecognitionResult> transcribe(
    BatchRecognitionRequest request,
  ) async {
    final index = _call++;
    if (index < delays.length) {
      await Future<void>.delayed(delays[index]);
    }
    final text = index < _texts.length ? _texts[index] : '';
    return BatchRecognitionResult(text: text);
  }

  @override
  Future<void> onClose() async {}
}

final class _FailingProvider extends IdempotentSpeechProvider
    implements BatchSpeechToTextProvider {
  @override
  SpeechProviderDescriptor get descriptor => SpeechProviderDescriptor(
    id: 'failing',
    displayName: 'Failing',
    capabilities: const <SpeechCapability>{SpeechCapability.batchSpeechToText},
  );

  @override
  Future<BatchRecognitionResult> transcribe(BatchRecognitionRequest request) =>
      Future<BatchRecognitionResult>.error(StateError('decode failed'));

  @override
  Future<void> onClose() async {}
}

void main() {
  group('BatchTranscriptionPipeline', () {
    test('emits one segment per decoded window', () async {
      final provider = _ScriptedProvider(<String>['ship the release']);
      final pipeline = BatchTranscriptionPipeline(provider: provider);

      final segments = await pipeline.transcribe(_speechFrames(8)).toList();

      expect(segments, hasLength(1));
      expect(segments.single.text, 'ship the release');
      expect(segments.single.trackId, 'me');
      expect(segments.single.start, Duration.zero);
      expect(segments.single.end, const Duration(milliseconds: 800));
    });

    test('never sends a silent window to the provider', () async {
      final provider = _ScriptedProvider(<String>['should not happen']);
      final pipeline = BatchTranscriptionPipeline(
        provider: provider,
        cutter: AudioWindowCutter(
          detectorFactory: () => const RmsSpeechActivityDetector(threshold: 1),
        ),
      );

      final segments = await pipeline.transcribe(_speechFrames(30)).toList();

      expect(segments, isEmpty);
      expect(provider.callCount, 0);
    });

    test(
      'emits segments in capture order despite uneven decode times',
      () async {
        // The first window decodes slowly; without serialization the second
        // would overtake it.
        final provider = _ScriptedProvider(
          <String>['first window', 'second window', 'third window'],
          delays: const <Duration>[
            Duration(milliseconds: 60),
            Duration(milliseconds: 1),
            Duration(milliseconds: 1),
          ],
        );
        final pipeline = BatchTranscriptionPipeline(provider: provider);

        final segments = await pipeline.transcribe(_speechFrames(150)).toList();

        expect(segments.length, greaterThanOrEqualTo(2));
        expect(segments.first.text, 'first window');
        expect(segments[1].text, 'second window');
        // Timeline stays monotonic.
        for (var i = 1; i < segments.length; i++) {
          expect(
            segments[i].start,
            greaterThanOrEqualTo(segments[i - 1].start),
          );
        }
      },
    );

    test('drops hallucinated text by default', () async {
      final provider = _ScriptedProvider(<String>['[BLANK_AUDIO]']);
      final pipeline = BatchTranscriptionPipeline(provider: provider);

      final segments = await pipeline.transcribe(_speechFrames(8)).toList();

      expect(provider.callCount, 1);
      expect(segments, isEmpty);
    });

    test('keeps hallucinated text when filtering is disabled', () async {
      final provider = _ScriptedProvider(<String>['[BLANK_AUDIO]']);
      final pipeline = BatchTranscriptionPipeline(
        provider: provider,
        filterHallucinations: false,
      );

      final segments = await pipeline.transcribe(_speechFrames(8)).toList();

      expect(segments.single.text, '[BLANK_AUDIO]');
    });

    test('drops empty decodes', () async {
      final provider = _ScriptedProvider(<String>['   ']);
      final pipeline = BatchTranscriptionPipeline(provider: provider);

      final segments = await pipeline.transcribe(_speechFrames(8)).toList();

      expect(segments, isEmpty);
    });

    test('forwards provider failures as stream errors', () async {
      final pipeline = BatchTranscriptionPipeline(provider: _FailingProvider());

      expect(pipeline.transcribe(_speechFrames(8)).toList(), throwsStateError);
    });

    test('forwards recognition options to the provider', () async {
      final provider = _RecordingProvider();
      final options = SpeechRecognitionOptions(
        modelId: 'parakeet-v3',
        languageTag: 'en-US',
      );
      final pipeline = BatchTranscriptionPipeline(
        provider: provider,
        options: options,
      );

      await pipeline.transcribe(_speechFrames(8)).toList();

      expect(provider.lastOptions?.modelId, 'parakeet-v3');
      expect(provider.lastOptions?.languageTag, 'en-US');
    });

    test('discards in-flight results after the consumer cancels', () async {
      final provider = _ScriptedProvider(
        <String>['slow result'],
        delays: const <Duration>[Duration(milliseconds: 80)],
      );
      final pipeline = BatchTranscriptionPipeline(provider: provider);
      final seen = <TranscriptSegment>[];

      final subscription = pipeline
          .transcribe(_speechFrames(8))
          .listen(seen.add);
      await pumpEventQueue();
      await subscription.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(seen, isEmpty);
    });
  });
}

final class _RecordingProvider extends IdempotentSpeechProvider
    implements BatchSpeechToTextProvider {
  SpeechRecognitionOptions? lastOptions;

  @override
  SpeechProviderDescriptor get descriptor => SpeechProviderDescriptor(
    id: 'recording',
    displayName: 'Recording',
    capabilities: const <SpeechCapability>{SpeechCapability.batchSpeechToText},
  );

  @override
  Future<BatchRecognitionResult> transcribe(
    BatchRecognitionRequest request,
  ) async {
    lastOptions = request.options;
    return BatchRecognitionResult(text: 'ok');
  }

  @override
  Future<void> onClose() async {}
}
