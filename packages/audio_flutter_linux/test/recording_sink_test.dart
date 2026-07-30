import 'dart:io';
import 'dart:typed_data';

import 'package:audio_flutter_linux/audio_flutter_linux.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('audio_flutter_linux_test');
  });

  tearDown(() async {
    if (temp.existsSync()) {
      await temp.delete(recursive: true);
    }
  });

  test('writes a WAV whose header describes the captured audio', () async {
    final String path = '${temp.path}/nested/capture.wav';
    final WavFileRecordingSink sink = WavFileRecordingSink(
      path,
      const PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
    );

    await sink.open();
    sink
      ..add(pcm16Ramp(100))
      ..add(pcm16Ramp(60, start: 100));
    await sink.close();

    final Uint8List bytes = await File(path).readAsBytes();
    final ByteData data = ByteData.sublistView(bytes);
    const int dataBytes = 160 * 2;

    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
    expect(data.getUint32(4, Endian.little), 36 + dataBytes);
    expect(data.getUint16(22, Endian.little), 1);
    expect(data.getUint32(24, Endian.little), 16000);
    expect(data.getUint32(28, Endian.little), 32000);
    expect(data.getUint16(34, Endian.little), 16);
    expect(data.getUint32(40, Endian.little), dataBytes);
    expect(bytes, hasLength(44 + dataBytes));
  });

  test(
    'stereo header reports the matching byte rate and block align',
    () async {
      final String path = '${temp.path}/stereo.wav';
      final WavFileRecordingSink sink = WavFileRecordingSink(
        path,
        const PlatformPcmFormat(sampleRate: 48000, channelCount: 2),
      );

      await sink.open();
      sink.add(pcm16Ramp(8));
      await sink.close();

      final ByteData data = ByteData.sublistView(
        await File(path).readAsBytes(),
      );

      expect(data.getUint16(22, Endian.little), 2);
      expect(data.getUint32(28, Endian.little), 48000 * 2 * 2);
      expect(data.getUint16(32, Endian.little), 4);
    },
  );

  test('an aborted recording still finalizes the prefix on disk', () async {
    final String path = '${temp.path}/aborted.wav';
    final WavFileRecordingSink sink = WavFileRecordingSink(
      path,
      const PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
    );

    await sink.open();
    sink.add(pcm16Ramp(32));
    await sink.abort();

    final ByteData data = ByteData.sublistView(await File(path).readAsBytes());
    expect(data.getUint32(40, Endian.little), 64);
  });

  test('writes after close are ignored rather than throwing', () async {
    final String path = '${temp.path}/closed.wav';
    final WavFileRecordingSink sink = WavFileRecordingSink(
      path,
      const PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
    );

    await sink.open();
    await sink.close();

    expect(() => sink.add(pcm16Ramp(4)), returnsNormally);
    expect(await File(path).length(), 44);
  });
}
