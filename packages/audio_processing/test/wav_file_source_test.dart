import 'dart:io';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:audio_processing/audio_processing_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'audio_processing_wav_source.',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'streams only the selected window in bounded frames after seek',
    () async {
      final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
      final String path = '${temporaryDirectory.path}/window.wav';
      await File(path).writeAsBytes(
        _wav(format, <double>[-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75]),
      );
      final WavFileAudioSourceSession session = await WavFileAudioSource(
        path: path,
        sourceId: 'recording',
        start: const Duration(milliseconds: 2),
        duration: const Duration(milliseconds: 4),
        chunkFrameCount: 2,
      ).prepare();

      expect(session.sourceFrameCount, 8);
      expect(session.windowStart, const Duration(milliseconds: 2));
      expect(session.windowDuration, const Duration(milliseconds: 4));
      await session.seek(const Duration(milliseconds: 3));
      final Future<List<AudioFrame>> collected = session.frames.toList();
      await session.start();
      final List<AudioFrame> frames = await collected;

      expect(frames.map((AudioFrame frame) => frame.frameCount), <int>[2, 1]);
      expect(frames.map((AudioFrame frame) => frame.sampleOffset), <int>[3, 5]);
      expect(
        frames.expand((AudioFrame frame) => frame.samples),
        closeToList(<double>[-0.25, 0, 0.25], 0.0001),
      );
      expect(frames.first.timestamp, const Duration(milliseconds: 3));
      expect(session.position, const Duration(milliseconds: 6));
      await session.close();
    },
  );

  test('decodes float32 WAV samples without whole-file buffering', () async {
    final AudioFormat format = AudioFormat(sampleRate: 48000, channels: 2);
    final String path = '${temporaryDirectory.path}/float.wav';
    await File(path).writeAsBytes(
      _wav(format, <double>[
        0.125,
        -0.25,
        0.5,
        -1,
      ], encoding: WavSampleEncoding.float32),
    );
    final WavFileAudioSourceSession session = await WavFileAudioSource(
      path: path,
      sourceId: 'float-recording',
      chunkFrameCount: 1,
    ).prepare();

    final Future<List<AudioFrame>> collected = session.frames.toList();
    await session.start();
    final List<AudioFrame> frames = await collected;

    expect(session.encoding, WavSampleEncoding.float32);
    expect(frames, hasLength(2));
    expect(frames.every((AudioFrame frame) => frame.frameCount == 1), isTrue);
    expect(
      frames.expand((AudioFrame frame) => frame.samples),
      closeToList(<double>[0.125, -0.25, 0.5, -1], 0.000001),
    );
    await session.close();
  });

  test('validates format arithmetic and the bounded header scan', () async {
    final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
    final Uint8List canonical = _wav(format, <double>[0, 1]);
    final String invalidPath = '${temporaryDirectory.path}/invalid.wav';
    final Uint8List invalid = Uint8List.fromList(canonical);
    ByteData.sublistView(invalid).setUint32(28, 999, Endian.little);
    await File(invalidPath).writeAsBytes(invalid);

    await expectLater(
      WavFileAudioSource(path: invalidPath, sourceId: 'invalid').prepare(),
      throwsA(
        isA<AudioFailure>().having(
          (AudioFailure failure) => failure.code,
          'code',
          'wav_file_invalid_header',
        ),
      ),
    );

    final String metadataPath = '${temporaryDirectory.path}/metadata.wav';
    await File(metadataPath).writeAsBytes(_withJunkChunk(canonical, 32));
    await expectLater(
      WavFileAudioSource(
        path: metadataPath,
        sourceId: 'metadata',
        maximumHeaderBytes: 44,
      ).prepare(),
      throwsA(
        isA<AudioFailure>().having(
          (AudioFailure failure) => failure.code,
          'code',
          'wav_file_invalid_header',
        ),
      ),
    );

    final WavFileAudioSourceSession accepted = await WavFileAudioSource(
      path: metadataPath,
      sourceId: 'metadata',
      maximumHeaderBytes: 128,
    ).prepare();
    final Future<List<AudioFrame>> frames = accepted.frames.toList();
    await accepted.start();
    expect(await frames, hasLength(1));
    await accepted.close();
  });

  test('rejects seeking outside the window or after start', () async {
    final AudioFormat format = AudioFormat(sampleRate: 1000, channels: 1);
    final String path = '${temporaryDirectory.path}/seek.wav';
    await File(path).writeAsBytes(_wav(format, <double>[0, 0, 0, 0]));
    final WavFileAudioSourceSession session = await WavFileAudioSource(
      path: path,
      sourceId: 'seek',
      start: const Duration(milliseconds: 1),
      duration: const Duration(milliseconds: 2),
    ).prepare();

    await expectLater(session.seek(Duration.zero), throwsRangeError);
    final Future<List<AudioFrame>> frames = session.frames.toList();
    await session.start();
    await frames;
    await expectLater(
      session.seek(const Duration(milliseconds: 2)),
      throwsStateError,
    );
    await session.close();
  });
}

Uint8List _wav(
  AudioFormat format,
  List<double> samples, {
  WavSampleEncoding encoding = WavSampleEncoding.pcm16,
}) {
  final WavEncoder encoder = WavEncoder(format: format, encoding: encoding)
    ..addFrame(
      AudioFrame(
        format: format,
        samples: Float32List.fromList(samples),
        sourceId: 'fixture',
        trackId: 'audio',
        clockId: 'fixture.timeline',
        sequence: 0,
        sampleOffset: 0,
        timestamp: Duration.zero,
      ),
    );
  return encoder.finish();
}

Uint8List _withJunkChunk(Uint8List canonical, int junkLength) {
  final Uint8List result = Uint8List(canonical.length + 8 + junkLength);
  result.setRange(0, 36, canonical);
  final ByteData data = ByteData.sublistView(result);
  _writeAscii(data, 36, 'JUNK');
  data.setUint32(40, junkLength, Endian.little);
  result.setRange(44 + junkLength, result.length, canonical, 36);
  data.setUint32(4, result.length - 8, Endian.little);
  return result;
}

void _writeAscii(ByteData data, int offset, String value) {
  for (var index = 0; index < value.length; index += 1) {
    data.setUint8(offset + index, value.codeUnitAt(index));
  }
}

Matcher closeToList(List<double> expected, double delta) => orderedEquals(
  <Matcher>[for (final double value in expected) closeTo(value, delta)],
);
