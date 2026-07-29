import 'dart:typed_data';

import 'package:audio_processing/audio_processing.dart';
import 'package:test/test.dart';

void main() {
  group('AudioRing', () {
    test('returns exactly the requested absolute range', () {
      final ring = AudioRing(capacity: 8)..append(<double>[0, 1, 2, 3, 4]);

      expect(ring.writeIndex, 5);
      expect(ring.samples(from: 1, to: 4), orderedEquals(<double>[1, 2, 3]));
      expect(
        ring.samples(from: 0, to: 5),
        orderedEquals(<double>[0, 1, 2, 3, 4]),
      );
    });

    test('wraps and clips ranges older than capacity', () {
      // 0 and 1 are evicted.
      final ring = AudioRing(capacity: 4)..append(<double>[0, 1, 2, 3, 4, 5]);

      expect(ring.writeIndex, 6);
      expect(ring.availableStart, 2);
      expect(
        ring.samples(from: 0, to: 6),
        orderedEquals(<double>[2, 3, 4, 5]),
        reason: 'the evicted head is clipped, never wrapped',
      );
      expect(ring.samples(from: 4, to: 6), orderedEquals(<double>[4, 5]));
      expect(
        ring.samples(from: 6, to: 9),
        isEmpty,
        reason: 'a future range is empty',
      );
    });

    test('keeps absolute indices across many wraps', () {
      final ring = AudioRing(capacity: 4);
      for (var index = 0; index < 100; index += 1) {
        ring.append(<double>[index.toDouble()]);
      }

      expect(ring.writeIndex, 100);
      expect(ring.availableStart, 96);
      expect(
        ring.samples(from: 96, to: 100),
        orderedEquals(<double>[96, 97, 98, 99]),
      );
      expect(
        ring.samples(from: 90, to: 98),
        orderedEquals(<double>[96, 97]),
        reason: 'both ends clip independently',
      );
    });

    test('accepts a Float32List and preserves float32 values', () {
      final ring = AudioRing(capacity: 3)
        ..append(Float32List.fromList(<double>[0.25, -0.5, 0.75]));

      expect(ring.samples(from: 0, to: 3), isA<Float32List>());
      expect(
        ring.samples(from: 0, to: 3),
        orderedEquals(<double>[0.25, -0.5, 0.75]),
      );
    });

    test('empty and inverted ranges return nothing', () {
      final ring = AudioRing(capacity: 4)..append(<double>[1, 2, 3]);

      expect(ring.samples(from: 2, to: 2), isEmpty);
      expect(ring.samples(from: 3, to: 1), isEmpty);
      expect(ring.samples(from: -10, to: 0), isEmpty);
      expect(
        ring.samples(from: -10, to: 2),
        orderedEquals(<double>[1, 2]),
        reason: 'a negative start clamps to the beginning of the stream',
      );
    });

    test('appending more than capacity at once keeps only the tail', () {
      final ring = AudioRing(capacity: 3)
        ..append(<double>[1, 2, 3, 4, 5, 6, 7]);

      expect(ring.writeIndex, 7);
      expect(ring.samples(from: 0, to: 7), orderedEquals(<double>[5, 6, 7]));
    });

    test('clear restarts the stream position', () {
      final ring = AudioRing(capacity: 4)
        ..append(<double>[1, 2, 3])
        ..clear();

      expect(ring.writeIndex, 0);
      expect(ring.availableStart, 0);
      expect(ring.samples(from: 0, to: 3), isEmpty);

      ring.append(<double>[9]);
      expect(ring.samples(from: 0, to: 1), orderedEquals(<double>[9]));
    });

    test('defaults to ten seconds at 16 kHz and rejects a dead capacity', () {
      expect(AudioRing.defaultCapacity, 160000);
      expect(AudioRing().capacity, 160000);
      expect(() => AudioRing(capacity: 0), throwsArgumentError);
      expect(() => AudioRing(capacity: -1), throwsArgumentError);
    });
  });
}
