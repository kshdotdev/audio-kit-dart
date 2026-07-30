import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:test/test.dart';

void main() {
  group('TurnCompletionAudio', () {
    test('pins the window policy of the model family', () {
      expect(TurnCompletionAudio.sampleRate, 16000);
      expect(TurnCompletionAudio.maximumWindow, const Duration(seconds: 8));
      expect(TurnCompletionAudio.defaultThreshold, 0.5);
    });
  });

  group('TurnCompletionRequest', () {
    test('wraps raw samples at the canonical rate', () {
      final request = TurnCompletionRequest.fromSamples(
        Float32List(16000),
        threshold: 0.7,
      );

      expect(request.audio.format.sampleRate, 16000);
      expect(request.audio.format.channels, 1);
      expect(request.audio.samples, hasLength(16000));
      expect(request.windowDuration, const Duration(seconds: 1));
      expect(request.threshold, 0.7);
      expect(request.cancellation, isNull);
      expect(request.providerOptions, isNull);
    });

    test('copies the caller buffer', () {
      final samples = Float32List.fromList(<double>[0.1, 0.2, 0.3]);
      final request = TurnCompletionRequest.fromSamples(samples);
      samples[0] = 1;

      expect(request.audio.samples[0], closeTo(0.1, 1e-6));
    });

    test('rejects a window that is not mono', () {
      expect(
        () => TurnCompletionRequest(
          audio: BufferedAudioSource(
            format: AudioFormat(sampleRate: 16000, channels: 2),
            samples: Float32List(320),
            sourceId: 'turn',
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects an empty window and an out-of-range threshold', () {
      expect(
        () => TurnCompletionRequest.fromSamples(Float32List(0)),
        throwsArgumentError,
      );
      expect(
        () =>
            TurnCompletionRequest.fromSamples(Float32List(160), threshold: 1.5),
        throwsArgumentError,
      );
    });

    test('carries cancellation and provider options through', () {
      final token = AudioCancellationController().token;
      final options = _Options();
      final request = TurnCompletionRequest.fromSamples(
        Float32List(160),
        cancellation: token,
        providerOptions: options,
      );

      expect(request.cancellation, same(token));
      expect(request.providerOptions, same(options));
    });
  });

  group('TurnCompletionScore', () {
    test('thresholding is strictly greater-than', () {
      expect(
        TurnCompletionScore.fromThreshold(
          probability: 0.5,
          threshold: 0.5,
        ).isComplete,
        isFalse,
        reason: 'a probability on the boundary leaves the turn open',
      );
      final complete = TurnCompletionScore.fromThreshold(
        probability: 0.51,
        threshold: 0.5,
      );
      expect(complete.isComplete, isTrue);
      expect(complete.probability, 0.51);
      expect(complete.threshold, 0.5);
    });

    test('keeps the probability even when the verdict disagrees with it', () {
      final score = TurnCompletionScore(
        probability: 0.9,
        isComplete: false,
        threshold: 0.95,
      );

      expect(score.probability, 0.9);
      expect(score.isComplete, isFalse);
      expect(score.toString(), contains('0.9'));
    });

    test('allows an undisclosed threshold and validates the numbers', () {
      expect(
        TurnCompletionScore(probability: 0.2, isComplete: false).threshold,
        isNull,
      );
      expect(
        () => TurnCompletionScore(probability: 1.2, isComplete: true),
        throwsArgumentError,
      );
      expect(
        () => TurnCompletionScore(
          probability: 0.2,
          isComplete: false,
          threshold: -0.1,
        ),
        throwsArgumentError,
      );
      expect(
        () => TurnCompletionScore(probability: double.nan, isComplete: false),
        throwsArgumentError,
      );
    });
  });

  group('TurnCompletionScorer', () {
    test('is discoverable through the registry by capability', () async {
      final registry = SpeechProviderRegistry();
      final scorer = _FakeScorer();
      registry.register(scorer);

      expect(
        registry.supporting<TurnCompletionScorer>(
          SpeechCapability.turnCompletion,
        ),
        <TurnCompletionScorer>[scorer],
      );

      final score = await scorer.scoreTurnCompletion(
        TurnCompletionRequest.fromSamples(Float32List(16000)),
      );
      expect(score.isComplete, isTrue);
      expect(score.threshold, TurnCompletionAudio.defaultThreshold);

      await registry.close();
      expect(scorer.isClosed, isTrue);
    });
  });
}

final class _Options implements SpeechProviderOptions {
  @override
  String get providerId => 'fake';
}

final class _FakeScorer extends IdempotentSpeechProvider
    implements TurnCompletionScorer {
  @override
  SpeechProviderDescriptor get descriptor => SpeechProviderDescriptor(
    id: 'fake',
    displayName: 'Fake',
    capabilities: const <SpeechCapability>{SpeechCapability.turnCompletion},
  );

  @override
  Future<TurnCompletionScore> scoreTurnCompletion(
    TurnCompletionRequest request,
  ) async {
    request.cancellation?.throwIfCancelled();
    return TurnCompletionScore.fromThreshold(
      probability: 0.87,
      threshold: request.threshold ?? TurnCompletionAudio.defaultThreshold,
    );
  }

  @override
  Future<void> onClose() async {}
}
