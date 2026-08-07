import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:test/test.dart';

void main() {
  final format = AudioFormat(sampleRate: 48000, channels: 1);

  test('feeds one eager consumer without retaining inactive frames', () async {
    final source = RealtimeAudioFeedSource(
      format: format,
      sourceId: 'remote-reference',
      trackId: 'remote',
      clockId: 'native-clock',
    );
    expect(source.add(_frame(0)), isFalse);

    final session = await source.prepare();
    final received = <AudioFrame>[];
    final done = session.frames.listen(received.add).asFuture<void>();
    await session.start();

    expect(source.add(_frame(1)), isTrue);
    expect(received.map((frame) => frame.sequence), <int>[1]);

    await session.stop();
    expect(source.add(_frame(2)), isFalse);
    await done;
    await session.close();
  });

  test('rejects format drift and a second prepare', () async {
    final source = RealtimeAudioFeedSource(
      format: format,
      sourceId: 'remote-reference',
      trackId: 'remote',
      clockId: 'native-clock',
    );
    final session = await source.prepare();
    session.frames.listen((_) {});
    await session.start();

    expect(
      () => source.add(
        AudioFrame.owned(
          format: AudioFormat(sampleRate: 16000, channels: 1),
          samples: Float32List(160),
          sourceId: 'remote-reference',
          trackId: 'remote',
          clockId: 'native-clock',
          sequence: 0,
          sampleOffset: 0,
          timestamp: Duration.zero,
        ),
      ),
      throwsArgumentError,
    );
    await expectLater(source.prepare(), throwsStateError);
    await session.close();
  });
}

AudioFrame _frame(int sequence) => AudioFrame.owned(
  format: AudioFormat(sampleRate: 48000, channels: 1),
  samples: Float32List(480),
  sourceId: 'remote-reference',
  trackId: 'remote',
  clockId: 'native-clock',
  sequence: sequence,
  sampleOffset: sequence * 480,
  timestamp: Duration(milliseconds: sequence * 10),
);
