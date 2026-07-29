import 'dart:typed_data';

import 'package:audio_flutter_linux/audio_flutter_linux.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

PlatformAudioFrame frame(int sequence) => PlatformAudioFrame(
  sessionId: 1,
  sequence: sequence,
  sampleOffset: sequence * 160,
  timestamp: Duration(milliseconds: sequence * 10),
  samples: Float32List(160),
);

void main() {
  test('delivers frames oldest first, bounded by maxFrames', () {
    final FrameRing ring = FrameRing(
      capacity: 4,
      policy: PlatformCaptureOverflowPolicy.dropOldest,
    );
    for (var index = 0; index < 3; index++) {
      expect(ring.add(frame(index)), FrameRingAdmission.accepted);
    }

    final List<PlatformAudioFrame> taken = ring.take(2);

    expect(taken.map((PlatformAudioFrame f) => f.sequence), <int>[0, 1]);
    expect(ring.length, 1);
    expect(
      taken.every((PlatformAudioFrame f) => f.droppedFramesBefore == 0),
      isTrue,
    );
  });

  test('dropOldest evicts the head and reports the gap on the next read', () {
    final FrameRing ring = FrameRing(
      capacity: 2,
      policy: PlatformCaptureOverflowPolicy.dropOldest,
    );
    ring
      ..add(frame(0))
      ..add(frame(1));

    expect(ring.add(frame(2)), FrameRingAdmission.displacedOldest);
    expect(ring.add(frame(3)), FrameRingAdmission.displacedOldest);

    final List<PlatformAudioFrame> taken = ring.take(2);

    expect(taken.map((PlatformAudioFrame f) => f.sequence), <int>[2, 3]);
    // Sequences 0 and 1 vanished, so the first surviving frame carries the gap.
    expect(taken.first.droppedFramesBefore, 2);
    expect(taken.last.droppedFramesBefore, 0);
  });

  test(
    'dropNewest discards arrivals and reports the gap on the next admit',
    () {
      final FrameRing ring = FrameRing(
        capacity: 2,
        policy: PlatformCaptureOverflowPolicy.dropNewest,
      );
      ring
        ..add(frame(0))
        ..add(frame(1));

      expect(ring.add(frame(2)), FrameRingAdmission.discarded);
      expect(ring.add(frame(3)), FrameRingAdmission.discarded);

      expect(ring.take(2).map((PlatformAudioFrame f) => f.sequence), <int>[
        0,
        1,
      ]);

      expect(ring.add(frame(4)), FrameRingAdmission.accepted);
      expect(ring.take(1).single.droppedFramesBefore, 2);
    },
  );

  test('failCapture signals overflow instead of dropping', () {
    final FrameRing ring = FrameRing(
      capacity: 1,
      policy: PlatformCaptureOverflowPolicy.failCapture,
    );
    ring.add(frame(0));

    expect(ring.add(frame(1)), FrameRingAdmission.overflowed);
    expect(ring.length, 1);
  });

  test('clear drops queued frames and pending gap accounting', () {
    final FrameRing ring = FrameRing(
      capacity: 1,
      policy: PlatformCaptureOverflowPolicy.dropOldest,
    );
    ring
      ..add(frame(0))
      ..add(frame(1))
      ..clear();

    expect(ring.isEmpty, isTrue);
    ring.add(frame(2));
    expect(ring.take(1).single.droppedFramesBefore, 0);
  });

  test('take on an empty ring returns nothing', () {
    final FrameRing ring = FrameRing(
      capacity: 2,
      policy: PlatformCaptureOverflowPolicy.dropOldest,
    );

    expect(ring.take(4), isEmpty);
    expect(ring.take(0), isEmpty);
  });
}
