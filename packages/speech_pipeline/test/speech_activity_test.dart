import 'dart:math' as math;
import 'dart:typed_data';

import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

/// Builds a sine tone of [amplitude] on the normalized float32 scale.
Float32List _tone(double amplitude, {int sampleCount = 1600}) {
  final samples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = amplitude * math.sin(2 * math.pi * 220 * i / 16000);
  }
  return samples;
}

Float32List _constant(double value, {int sampleCount = 1600}) =>
    Float32List(sampleCount)..fillRange(0, sampleCount, value);

void main() {
  group('rmsOfSamples', () {
    test('returns zero for an empty buffer', () {
      expect(rmsOfSamples(Float32List(0)), 0);
    });

    test('measures amplitude on the normalized 0-1 scale', () {
      expect(rmsOfSamples(_constant(0.5)), closeTo(0.5, 1e-6));
      // A sine's RMS is its amplitude over root two.
      expect(rmsOfSamples(_tone(1)), closeTo(1 / math.sqrt2, 1e-3));
    });
  });

  group('RmsSpeechActivityDetector', () {
    // The scale calibration guard. Control Center divides each PCM16 sample by
    // 32768 before computing RMS, so its 0.012 threshold was already on the
    // normalized 0-1 scale that float32 frames use natively. If that constant
    // were ever mistaken for a raw PCM16 amplitude (as the AEC delay
    // estimator's minNearStd genuinely is), the gate would either never fire or
    // always fire, and the silent-window skip would fail silently.
    const detector = RmsSpeechActivityDetector();

    test('default threshold is on the normalized scale', () {
      expect(detector.threshold, 0.012);
      expect(detector.threshold, lessThan(1));
    });

    test('fires on speech-level audio', () {
      // Conversational speech sits far above the floor at any plausible level.
      expect(detector.isSpeech(_tone(0.3)), isTrue);
      expect(detector.isSpeech(_tone(0.05)), isTrue);
      // Quiet but real speech, an order of magnitude under normal levels.
      expect(detector.isSpeech(_tone(0.02)), isTrue);
    });

    test('stays quiet on silence and dither-level noise', () {
      expect(detector.isSpeech(Float32List(1600)), isFalse);
      expect(detector.isSpeech(_tone(0.001)), isFalse);
      // One PCM16 least-significant bit, expressed on the float32 scale.
      expect(detector.isSpeech(_constant(1 / 32768)), isFalse);
    });

    test('honours a custom threshold', () {
      const strict = RmsSpeechActivityDetector(threshold: 0.5);
      expect(strict.isSpeech(_tone(0.3)), isFalse);
      expect(strict.isSpeech(_tone(0.9)), isTrue);
    });
  });

  group('AndSpeechActivityDetector', () {
    test('fires only when every detector agrees', () {
      final gate = AndSpeechActivityDetector(<SpeechActivityDetector>[
        const RmsSpeechActivityDetector(threshold: 0.01),
        const RmsSpeechActivityDetector(threshold: 0.4),
      ]);

      expect(gate.isSpeech(_tone(0.9)), isTrue); // Both agree.
      expect(gate.isSpeech(_tone(0.1)), isFalse); // Only the loose one agrees.
    });

    test('evaluates every detector so stateful ones see each chunk', () {
      final first = _CountingDetector(speech: false);
      final second = _CountingDetector(speech: true);
      final gate = AndSpeechActivityDetector(<SpeechActivityDetector>[
        first,
        second,
      ]);

      expect(gate.isSpeech(_tone(0.3)), isFalse);
      // No short-circuit: the second detector still saw the chunk.
      expect(first.calls, 1);
      expect(second.calls, 1);
    });

    test('forwards reset and dispose to every detector', () {
      final detector = _CountingDetector(speech: true);
      final gate = AndSpeechActivityDetector(<SpeechActivityDetector>[
        detector,
      ]);

      gate
        ..reset()
        ..dispose();

      expect(detector.resets, 1);
      expect(detector.disposals, 1);
    });

    test('rejects an empty detector list', () {
      expect(
        () => AndSpeechActivityDetector(const <SpeechActivityDetector>[]),
        throwsArgumentError,
      );
    });
  });
}

final class _CountingDetector implements SpeechActivityDetector {
  _CountingDetector({required this.speech});

  final bool speech;
  int calls = 0;
  int resets = 0;
  int disposals = 0;

  @override
  bool isSpeech(Float32List samples) {
    calls++;
    return speech;
  }

  @override
  void reset() => resets++;

  @override
  void dispose() => disposals++;
}
