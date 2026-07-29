import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';
import 'package:test/test.dart';

void main() {
  group('AdaptiveGain', () {
    test('amplifies quiet capture toward the target peak', () {
      final gain = AdaptiveGain();
      final output = gain.apply(_chunk(peak: 0.05));

      expect(gain.runningPeak, closeTo(0.05, 1e-9));
      expect(gain.gain, closeTo(6, 1e-6));
      expect(_peakOf(output), closeTo(0.3, 1e-6));
    });

    test('never amplifies beyond the maximum gain', () {
      final gain = AdaptiveGain();
      final output = gain.apply(_chunk(peak: 0.001));

      expect(gain.gain, 30);
      expect(_peakOf(output), closeTo(0.03, 1e-6));
    });

    test('never attenuates loud capture', () {
      final gain = AdaptiveGain();
      final input = _chunk(peak: 0.9);
      final output = gain.apply(input);

      expect(gain.gain, 1);
      expect(identical(output, input), isTrue);
      expect(_peakOf(output), closeTo(0.9, 1e-6));
    });

    test('passes through inside the deadband and scales just outside it', () {
      // 0.3 / 0.29 = 1.034, inside the 1.05 deadband.
      final inside = AdaptiveGain();
      final quiet = _chunk(peak: 0.29);
      expect(identical(inside.apply(quiet), quiet), isTrue);
      expect(inside.gain, 1);

      // 0.3 / 0.28 = 1.071, outside it.
      final outside = AdaptiveGain();
      final quieter = _chunk(peak: 0.28);
      expect(identical(outside.apply(quieter), quieter), isFalse);
      expect(outside.gain, closeTo(0.3 / 0.28, 1e-6));
    });

    test('keeps true silence silent', () {
      final gain = AdaptiveGain();
      final silence = Float32List(64);
      final output = gain.apply(silence);

      expect(identical(output, silence), isTrue);
      expect(gain.runningPeak, 0);
      expect(gain.gain, 1);
    });

    test('holds the running peak against a single quiet chunk', () {
      final gain = AdaptiveGain()..apply(_chunk(peak: 0.5));
      final quiet = _chunk(peak: 0.01);
      final output = gain.apply(quiet);

      expect(
        identical(output, quiet),
        isTrue,
        reason: 'the pause after speech is not pumped up to the target peak',
      );
      expect(gain.runningPeak, closeTo(0.5 * 0.995, 1e-9));
    });

    test('decays the running peak once per chunk', () {
      final gain = AdaptiveGain()..apply(_chunk(peak: 0.5));
      for (var chunk = 0; chunk < 100; chunk += 1) {
        gain.apply(Float32List(64));
      }

      expect(gain.runningPeak, closeTo(0.5 * math.pow(0.995, 100), 1e-9));
      expect(
        gain.gain,
        1,
        reason: '100 chunks (~26 s) of silence is not yet a new level',
      );
    });

    test('tracks a rising peak immediately', () {
      final gain = AdaptiveGain()..apply(_chunk(peak: 0.02));
      expect(gain.gain, closeTo(15, 1e-6));

      gain.apply(_chunk(peak: 0.4));
      expect(gain.runningPeak, closeTo(0.4, 1e-6));
      expect(gain.gain, 1);
    });

    test('reset forgets the level history', () {
      final gain = AdaptiveGain()..apply(_chunk(peak: 0.5));
      gain.reset();

      expect(gain.runningPeak, 0);
      final quiet = _chunk(peak: 0.01);
      expect(identical(gain.apply(quiet), quiet), isFalse);
    });

    test('exposes its ported constants and validates overrides', () {
      final gain = AdaptiveGain();

      expect(gain.targetPeak, 0.3);
      expect(gain.maxGain, 30);
      expect(gain.decay, 0.995);
      expect(AdaptiveGain.deadband, 1.05);
      expect(AdaptiveGain.silenceFloor, 1e-6);
      expect(() => AdaptiveGain(targetPeak: 0), throwsArgumentError);
      expect(() => AdaptiveGain(maxGain: 0.5), throwsArgumentError);
      expect(() => AdaptiveGain(decay: 1.5), throwsArgumentError);
      expect(() => AdaptiveGain(decay: 0), throwsArgumentError);
    });
  });

  group('AdaptiveGainProcessor', () {
    test('amplifies quiet frames and preserves timeline metadata', () {
      final processor = AdaptiveGainProcessor();
      final frame = _frame(
        peak: 0.05,
        sequence: 7,
        sampleOffset: 640,
        timestamp: const Duration(milliseconds: 40),
      );
      final output = processor.process(frame).single;

      expect(_peakOf(output.samples), closeTo(0.3, 1e-6));
      expect(output.format, frame.format);
      expect(output.sourceId, frame.sourceId);
      expect(output.trackId, frame.trackId);
      expect(output.clockId, frame.clockId);
      expect(output.sequence, 7);
      expect(output.sampleOffset, 640);
      expect(output.timestamp, const Duration(milliseconds: 40));
    });

    test('passes healthy frames through untouched', () {
      final processor = AdaptiveGainProcessor();
      final frame = _frame(peak: 0.8);
      final output = processor.process(frame).single;

      expect(_peakOf(output.samples), closeTo(0.8, 1e-6));
      expect(processor.gainFor(AudioStreamKey.fromFrame(frame))!.gain, 1);
    });

    test('keeps one running peak per stream', () {
      final processor = AdaptiveGainProcessor();
      processor.process(_frame(peak: 0.9, trackId: 'loud'));
      final quiet = processor
          .process(_frame(peak: 0.05, trackId: 'quiet'))
          .single;

      expect(
        _peakOf(quiet.samples),
        closeTo(0.3, 1e-6),
        reason: 'a loud system track must not silence a quiet microphone',
      );
    });

    test('a discontinuity drops the level history', () {
      final processor = AdaptiveGainProcessor();
      processor.process(_frame(peak: 0.9));

      final continuous = processor.process(_frame(peak: 0.05, sequence: 1));
      expect(_peakOf(continuous.single.samples), closeTo(0.05, 1e-6));

      final restarted = processor.process(
        _frame(
          peak: 0.05,
          sequence: 2,
          discontinuity: AudioDiscontinuity(
            reason: AudioDiscontinuityReason.sourceRestart,
          ),
        ),
      );
      expect(_peakOf(restarted.single.samples), closeTo(0.3, 1e-6));
      expect(
        restarted.single.discontinuity?.reason,
        AudioDiscontinuityReason.sourceRestart,
        reason: 'continuity metadata is forwarded, not swallowed',
      );
    });

    test('flush emits nothing and reset drops state', () {
      final processor = AdaptiveGainProcessor();
      final frame = _frame(peak: 0.9);
      final key = AudioStreamKey.fromFrame(frame);
      processor.process(frame);

      expect(processor.flush(), isEmpty);
      expect(processor.gainFor(key), isNotNull);
      processor.reset(stream: key);
      expect(processor.gainFor(key), isNull);

      processor.process(frame);
      processor.reset();
      expect(processor.gainFor(key), isNull);
    });
  });
}

Float32List _chunk({required double peak, int length = 64}) {
  final samples = Float32List(length);
  for (var index = 0; index < length; index += 1) {
    samples[index] = (index.isEven ? peak : -peak) * (index == 0 ? 1 : 0.5);
  }
  samples[0] = peak;
  return samples;
}

double _peakOf(Float32List samples) {
  var peak = 0.0;
  for (final sample in samples) {
    final magnitude = sample.abs();
    if (magnitude > peak) {
      peak = magnitude;
    }
  }
  return peak;
}

AudioFrame _frame({
  required double peak,
  int sampleRate = 16000,
  int channels = 1,
  String trackId = 'track',
  int sequence = 0,
  int sampleOffset = 0,
  Duration timestamp = Duration.zero,
  AudioDiscontinuity? discontinuity,
}) => AudioFrame.owned(
  format: AudioFormat(sampleRate: sampleRate, channels: channels),
  samples: _chunk(peak: peak),
  sourceId: 'source',
  trackId: trackId,
  clockId: 'clock',
  sequence: sequence,
  sampleOffset: sampleOffset,
  timestamp: timestamp,
  discontinuity: discontinuity,
);
