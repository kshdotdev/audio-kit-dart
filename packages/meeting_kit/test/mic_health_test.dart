// Ported from Control Center's meeting_mic_health_test.dart,
// MIT (c) 2026 Samuel Alev. See NOTICE.

import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing.dart';
import 'package:meeting_kit/meeting_kit.dart';
import 'package:test/test.dart';

Duration ms(int value) => Duration(milliseconds: value);

void main() {
  group('MicHealthTracker.health', () {
    test('is ok with no far activity to compare against', () {
      final tracker = MicHealthTracker();
      for (var t = 0; t <= 5000; t += 100) {
        // The near channel is silent, but nobody else is talking either.
        tracker.noteNear(0, ms(t));
      }

      expect(tracker.health, MicHealth.ok);
      expect(tracker.isNearSilentWhileFarActive, isFalse);
    });

    test('flags a silent microphone while the far end plays', () {
      final tracker = MicHealthTracker();
      for (var t = 0; t <= 4000; t += 100) {
        tracker.noteFar(0.3, ms(t));
        tracker.noteNear(0, ms(t));
      }

      expect(tracker.health, MicHealth.silentWhileFarActive);
      expect(tracker.isNearSilentWhileFarActive, isTrue);
    });

    test('stays ok when the microphone is also carrying audio', () {
      final tracker = MicHealthTracker();
      for (var t = 0; t <= 4000; t += 100) {
        tracker.noteFar(0.3, ms(t));
        tracker.noteNear(0.2, ms(t));
      }

      expect(tracker.health, MicHealth.ok);
    });

    test('does not flag a pause shorter than the confirm window', () {
      final tracker = MicHealthTracker(confirmAfter: ms(3000));
      for (var t = 0; t <= 1000; t += 100) {
        tracker.noteFar(0.3, ms(t));
        tracker.noteNear(0.2, ms(t));
      }
      for (var t = 1100; t <= 2500; t += 100) {
        tracker.noteFar(0.3, ms(t));
        tracker.noteNear(0, ms(t));
      }

      expect(tracker.health, MicHealth.ok);
    });

    test('clears once far activity goes stale', () {
      final tracker = MicHealthTracker();
      for (var t = 0; t <= 4000; t += 100) {
        tracker.noteFar(0.3, ms(t));
        tracker.noteNear(0, ms(t));
      }
      expect(tracker.isNearSilentWhileFarActive, isTrue);

      for (var t = 4100; t <= 7000; t += 100) {
        tracker.noteFar(0, ms(t));
        tracker.noteNear(0, ms(t));
      }

      expect(tracker.health, MicHealth.ok);
    });

    test('reset clears the verdict and the level', () {
      final tracker = MicHealthTracker();
      for (var t = 0; t <= 4000; t += 100) {
        tracker.noteFar(0.3, ms(t));
        tracker.noteNear(0, ms(t));
      }
      expect(tracker.isNearSilentWhileFarActive, isTrue);

      tracker.reset();

      expect(tracker.health, MicHealth.ok);
      expect(tracker.level, 0);
    });
  });

  group('MicHealthTracker.level', () {
    test('tracks the near RMS and stays within 0 to 1', () {
      final tracker = MicHealthTracker(levelSmoothing: 1);

      tracker.noteNear(0.5, ms(0));
      expect(tracker.level, closeTo(0.5, 1e-9));

      tracker.noteNear(0, ms(100));
      expect(tracker.level, closeTo(0, 1e-9));
    });

    test('smooths toward the target with a partial factor', () {
      final tracker = MicHealthTracker(levelSmoothing: 0.4);

      tracker.noteNear(1, ms(0));
      expect(tracker.level, closeTo(0.4, 1e-9));

      tracker.noteNear(1, ms(100));
      expect(tracker.level, closeTo(0.64, 1e-9));
    });

    test('clamps an out-of-range reading', () {
      final tracker = MicHealthTracker(levelSmoothing: 1);
      tracker.noteNear(4, ms(0));
      expect(tracker.level, closeTo(1, 1e-9));
    });
  });

  group('composition with AudioMeter', () {
    test('consumes meter readings without recomputing RMS', () {
      final meter = AudioMeter();
      final tracker = MicHealthTracker();
      final format = AudioFormat(sampleRate: 16000, channels: 1);

      AudioFrame frame(double amplitude, int sequence, String track) {
        return AudioFrame.owned(
          format: format,
          samples: Float32List.fromList(List<double>.filled(160, amplitude)),
          sourceId: 'capture',
          trackId: track,
          clockId: 'capture',
          sequence: sequence,
          sampleOffset: sequence * 160,
          timestamp: ms(sequence * 10),
        );
      }

      // A constant-amplitude block has an RMS equal to that amplitude, so the
      // tracker sees exactly what the meter measured.
      final reading = meter.process(frame(0.5, 0, 'near'));
      expect(reading.rms, closeTo(0.5, 1e-6));

      tracker.noteNearReading(reading);
      expect(tracker.level, greaterThan(0));

      for (var i = 1; i <= 400; i++) {
        tracker.noteFarReading(meter.process(frame(0.3, i, 'far')));
        tracker.noteNearReading(meter.process(frame(0, i, 'near')));
      }

      expect(tracker.health, MicHealth.silentWhileFarActive);
    });
  });

  group('MicHealthTracker validation', () {
    test('rejects out-of-range floors and factors', () {
      expect(() => MicHealthTracker(nearFloor: -1), throwsArgumentError);
      expect(() => MicHealthTracker(farFloor: 2), throwsArgumentError);
      expect(() => MicHealthTracker(levelSmoothing: 0), throwsArgumentError);
      expect(
        () => MicHealthTracker(confirmAfter: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => MicHealthTracker(farRecencyWindow: Duration.zero),
        throwsArgumentError,
      );
    });
  });
}
