import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';
import 'package:test/test.dart';

void main() {
  group('SpeechProviderDescriptor', () {
    test('requires nested descriptors to use the provider ID', () {
      expect(
        () => SpeechProviderDescriptor(
          id: 'provider-a',
          displayName: 'Provider A',
          capabilities: const {SpeechCapability.batchSpeechToText},
          models: [
            SpeechModelDescriptor(
              id: 'model',
              providerId: 'provider-b',
              displayName: 'Model',
              capabilities: const {SpeechCapability.batchSpeechToText},
            ),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('SpeechProviderRegistry', () {
    test('looks up typed providers and capabilities', () {
      final registry = SpeechProviderRegistry();
      final provider = _FakeProvider('local');
      registry.register(provider);

      expect(registry['local'], same(provider));
      expect(registry.find<_FakeProvider>('local'), same(provider));
      expect(
        registry.supporting<_FakeProvider>(SpeechCapability.batchSpeechToText),
        [provider],
      );
      expect(() => registry.register(_FakeProvider('local')), throwsStateError);
    });

    test('close is idempotent and closes every provider', () async {
      final registry = SpeechProviderRegistry();
      final first = _FakeProvider('first');
      final second = _FakeProvider('second');
      registry
        ..register(first)
        ..register(second);

      await registry.close();
      await registry.close();

      expect(first.closeCount, 1);
      expect(second.closeCount, 1);
      expect(registry.providers, isEmpty);
    });
  });

  test('transcript confidence is validated', () {
    expect(
      () => SpeechTranscript(text: 'hello', confidence: 1.1),
      throwsArgumentError,
    );
  });

  group('runtime contract validation', () {
    final AudioFormat format = AudioFormat(sampleRate: 16000, channels: 1);

    test('rejects invalid probabilities and event offsets', () {
      expect(
        () => VoiceActivityStarted(probability: double.nan, at: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => EndOfUtteranceEvent(
          probability: 0.5,
          at: const Duration(microseconds: -1),
          isFinal: false,
        ),
        throwsArgumentError,
      );
      expect(
        () => RecognitionPartial(
          transcript: SpeechTranscript(text: 'partial'),
          revision: -1,
          at: Duration.zero,
        ),
        throwsArgumentError,
      );
    });

    test('rejects invalid VAD and synthesis parameters in release mode', () {
      expect(
        () => VoiceActivityDetectionRequest(
          inputFormat: format,
          startThreshold: double.infinity,
        ),
        throwsArgumentError,
      );
      expect(
        () => VoiceActivityDetectionRequest(
          inputFormat: format,
          minimumSpeech: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => SpeechSynthesisRequest(text: ' ', rate: 1),
        throwsArgumentError,
      );
      expect(
        () => SpeechSynthesisRequest(text: 'hello', rate: double.nan),
        throwsArgumentError,
      );
      expect(
        () => SpeechSynthesisRequest(text: 'hello', pitch: double.infinity),
        throwsArgumentError,
      );
    });

    test('rejects inconsistent diarization and segment bounds', () {
      expect(
        () => DiarizationRequest(
          inputFormat: format,
          minimumSpeakers: 3,
          maximumSpeakers: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => DiarizationRequest(inputFormat: format, minimumSpeakers: 0),
        throwsArgumentError,
      );
      expect(
        () => BatchRecognitionSegment(
          text: 'invalid',
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 1),
        ),
        throwsArgumentError,
      );
    });

    test('requires stable safe failure metadata', () {
      expect(
        () => SpeechFailure(
          code: 'not stable',
          stage: 'recognition',
          safeMessage: 'Unable to recognize speech.',
        ),
        throwsArgumentError,
      );
      expect(
        () => SpeechFailure(
          code: 'recognition_failed',
          stage: '',
          safeMessage: 'Unable to recognize speech.',
        ),
        throwsArgumentError,
      );
      expect(
        () => SpeechFailure(
          code: 'recognition_failed',
          stage: 'recognition',
          safeMessage: ' ',
        ),
        throwsArgumentError,
      );
    });
  });
}

final class _FakeProvider implements SpeechProvider {
  _FakeProvider(String id)
    : descriptor = SpeechProviderDescriptor(
        id: id,
        displayName: id,
        capabilities: const {SpeechCapability.batchSpeechToText},
      );

  @override
  final SpeechProviderDescriptor descriptor;

  int closeCount = 0;

  @override
  Future<void> close() async {
    closeCount++;
  }
}
