import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'wav.dart';

const int canonicalWavHeaderLength = 44;

Uint8List buildCanonicalWavHeader({
  required AudioFormat format,
  required WavSampleEncoding encoding,
  required int dataLength,
}) {
  if (dataLength < 0 || dataLength > 0xffffffff - 36) {
    throw RangeError.range(dataLength, 0, 0xffffffff - 36, 'dataLength');
  }
  final ByteData header = ByteData(canonicalWavHeaderLength);
  writeWavAscii(header, 0, 'RIFF');
  header.setUint32(4, 36 + dataLength, Endian.little);
  writeWavAscii(header, 8, 'WAVE');
  writeWavAscii(header, 12, 'fmt ');
  header
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, encoding.formatCode, Endian.little)
    ..setUint16(22, format.channels, Endian.little)
    ..setUint32(24, format.sampleRate, Endian.little)
    ..setUint32(
      28,
      format.sampleRate * format.channels * encoding.bytesPerSample,
      Endian.little,
    )
    ..setUint16(32, format.channels * encoding.bytesPerSample, Endian.little)
    ..setUint16(34, encoding.bitsPerSample, Endian.little);
  writeWavAscii(header, 36, 'data');
  header.setUint32(40, dataLength, Endian.little);
  return header.buffer.asUint8List();
}

void validateCanonicalWavHeader(
  Uint8List bytes, {
  required AudioFormat expectedFormat,
  required WavSampleEncoding expectedEncoding,
}) {
  if (bytes.length < canonicalWavHeaderLength) {
    throw const FormatException('The canonical WAV header is truncated.');
  }
  final ByteData data = ByteData.sublistView(bytes);
  if (readWavAscii(data, 0, 4) != 'RIFF' ||
      readWavAscii(data, 8, 4) != 'WAVE' ||
      readWavAscii(data, 12, 4) != 'fmt ' ||
      readWavAscii(data, 36, 4) != 'data') {
    throw const FormatException('The canonical WAV header is invalid.');
  }
  final int formatCode = data.getUint16(20, Endian.little);
  final int channels = data.getUint16(22, Endian.little);
  final int sampleRate = data.getUint32(24, Endian.little);
  final int byteRate = data.getUint32(28, Endian.little);
  final int blockAlign = data.getUint16(32, Endian.little);
  final int bitsPerSample = data.getUint16(34, Endian.little);
  final int expectedBlockAlign =
      expectedFormat.channels * expectedEncoding.bytesPerSample;
  if (formatCode != expectedEncoding.formatCode ||
      bitsPerSample != expectedEncoding.bitsPerSample ||
      channels != expectedFormat.channels ||
      sampleRate != expectedFormat.sampleRate ||
      blockAlign != expectedBlockAlign ||
      byteRate != expectedFormat.sampleRate * expectedBlockAlign) {
    throw const FormatException(
      'The WAV header does not match the expected recording format.',
    );
  }
}

int canonicalWavDeclaredDataLength(Uint8List bytes) {
  if (bytes.length < canonicalWavHeaderLength) {
    throw const FormatException('The canonical WAV header is truncated.');
  }
  return ByteData.sublistView(bytes).getUint32(40, Endian.little);
}

void writeWavAscii(ByteData data, int offset, String value) {
  for (var index = 0; index < value.length; index += 1) {
    data.setUint8(offset + index, value.codeUnitAt(index));
  }
}

String readWavAscii(ByteData data, int offset, int length) =>
    String.fromCharCodes(
      List<int>.generate(length, (int index) => data.getUint8(offset + index)),
    );
