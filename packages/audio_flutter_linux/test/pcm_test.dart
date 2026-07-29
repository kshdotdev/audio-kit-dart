import 'dart:typed_data';

import 'package:audio_flutter_linux/audio_flutter_linux.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes signed 16-bit little-endian PCM to normalized float32', () {
    final Uint8List bytes = Uint8List(8);
    final ByteData data = ByteData.sublistView(bytes)
      ..setInt16(0, 0, Endian.little)
      ..setInt16(2, 32767, Endian.little)
      ..setInt16(4, -32768, Endian.little)
      ..setInt16(6, 16384, Endian.little);

    final Float32List samples = decodeS16le(
      Uint8List.sublistView(ByteData.sublistView(data)),
    );

    expect(samples, hasLength(4));
    expect(samples[0], 0);
    expect(samples[1], closeTo(1, 1e-4));
    expect(samples[2], -1);
    expect(samples[3], closeTo(0.5, 1e-6));
  });

  test('encode clamps rather than wrapping out-of-range samples', () {
    final Uint8List bytes = encodeS16le(
      Float32List.fromList(<double>[2, -2, 0, double.nan]),
    );
    final ByteData data = ByteData.sublistView(bytes);

    expect(data.getInt16(0, Endian.little), 32767);
    expect(data.getInt16(2, Endian.little), -32768);
    expect(data.getInt16(4, Endian.little), 0);
    expect(data.getInt16(6, Endian.little), 0);
  });

  test('round-trips audio within one quantization step', () {
    final Float32List original = Float32List.fromList(<double>[
      0,
      0.25,
      -0.25,
      0.75,
      -0.75,
    ]);

    final Float32List roundTripped = decodeS16le(encodeS16le(original));

    for (var index = 0; index < original.length; index++) {
      expect(roundTripped[index], closeTo(original[index], 1 / 32768));
    }
  });

  test('decoding ignores a trailing partial sample', () {
    expect(decodeS16le(Uint8List.fromList(<int>[1, 0, 2])), hasLength(1));
  });
}
