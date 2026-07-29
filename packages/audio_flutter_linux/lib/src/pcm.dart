import 'dart:typed_data';

/// Scale between float32 `[-1, 1]` audio and signed 16-bit PCM.
const double _pcm16Scale = 32768;
const int _pcm16Min = -32768;
const int _pcm16Max = 32767;

/// Decodes interleaved signed 16-bit little-endian PCM into float32 `[-1, 1]`.
///
/// [bytes] must hold whole samples; callers accumulate partial samples across
/// chunk boundaries before decoding.
Float32List decodeS16le(Uint8List bytes) {
  final int sampleCount = bytes.lengthInBytes ~/ 2;
  final ByteData data = ByteData.sublistView(bytes);
  final Float32List samples = Float32List(sampleCount);
  for (var index = 0; index < sampleCount; index++) {
    samples[index] = data.getInt16(index * 2, Endian.little) / _pcm16Scale;
  }
  return samples;
}

/// Encodes float32 `[-1, 1]` audio as interleaved signed 16-bit little-endian
/// PCM, clamping rather than wrapping on out-of-range input.
Uint8List encodeS16le(Float32List samples) {
  final Uint8List bytes = Uint8List(samples.length * 2);
  final ByteData data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples.length; index++) {
    final double sample = samples[index];
    var scaled = (sample.isNaN ? 0.0 : sample * _pcm16Scale).round();
    if (scaled < _pcm16Min) {
      scaled = _pcm16Min;
    } else if (scaled > _pcm16Max) {
      scaled = _pcm16Max;
    }
    data.setInt16(index * 2, scaled, Endian.little);
  }
  return bytes;
}
