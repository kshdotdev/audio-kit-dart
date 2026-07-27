import 'dart:async';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:test/test.dart';

void main() {
  final AudioFormat format = AudioFormat(sampleRate: 10, channels: 1);

  test('is cold, chunked, ordered, and subscribable before start', () async {
    final BufferedAudioSource source = BufferedAudioSource(
      format: format,
      samples: Float32List.fromList(<double>[1, 2, 3, 4, 5]),
      sourceId: 'memory',
      chunkFrameCount: 2,
    );
    final AudioSourceSession session = await source.prepare();
    final List<AudioFrame> frames = <AudioFrame>[];
    final StreamSubscription<AudioFrame> subscription = session.frames.listen(
      frames.add,
    );
    expect(frames, isEmpty);

    await session.start();

    expect(frames, hasLength(3));
    expect(
      frames.map((AudioFrame frame) => frame.samples).toList(),
      <List<double>>[
        <double>[1, 2],
        <double>[3, 4],
        <double>[5],
      ],
    );
    expect(frames.map((AudioFrame frame) => frame.sequence), <int>[0, 1, 2]);
    expect(frames.map((AudioFrame frame) => frame.sampleOffset), <int>[
      0,
      2,
      4,
    ]);
    expect(session.status.state, AudioSessionState.finished);
    await subscription.cancel();
    await session.close();
  });

  test('pause/resume applies cooperative source backpressure', () async {
    final BufferedAudioSource source = BufferedAudioSource(
      format: format,
      samples: Float32List.fromList(<double>[1, 2, 3, 4]),
      sourceId: 'memory',
      chunkFrameCount: 1,
    );
    final AudioSourceSession session = await source.prepare();
    final List<AudioFrame> frames = <AudioFrame>[];
    final Completer<void> paused = Completer<void>();
    final StreamSubscription<AudioFrame> subscription = session.frames.listen((
      AudioFrame frame,
    ) {
      frames.add(frame);
      if (frames.length == 1) {
        unawaited(session.pause().then((_) => paused.complete()));
      }
    });

    final Future<void> running = session.start();
    await paused.future;
    await Future<void>.delayed(Duration.zero);
    expect(frames, hasLength(1));
    await session.resume();
    await running;
    expect(frames, hasLength(4));

    await subscription.cancel();
    await session.close();
  });

  test(
    'subscription pause signal applies bounded source backpressure',
    () async {
      final BufferedAudioSource source = BufferedAudioSource(
        format: format,
        samples: Float32List.fromList(<double>[1, 2, 3, 4]),
        sourceId: 'memory',
        chunkFrameCount: 1,
      );
      final AudioSourceSession session = await source.prepare();
      final Completer<void> resumeSignal = Completer<void>();
      final List<AudioFrame> frames = <AudioFrame>[];
      late final StreamSubscription<AudioFrame> subscription;
      subscription = session.frames.listen((AudioFrame frame) {
        frames.add(frame);
        if (frames.length == 1) {
          subscription.pause(resumeSignal.future);
        }
      });

      final Future<void> running = session.start();
      await Future<void>.delayed(Duration.zero);
      expect(frames, hasLength(1));
      resumeSignal.complete();
      await running;
      expect(frames, hasLength(4));

      await subscription.cancel();
      await session.close();
    },
  );

  test(
    'frame stream is single-consumer and paused listener cannot hang close',
    () async {
      final BufferedAudioSource source = BufferedAudioSource(
        format: format,
        samples: Float32List.fromList(<double>[1, 2, 3, 4]),
        sourceId: 'memory',
        chunkFrameCount: 1,
      );
      final AudioSourceSession session = await source.prepare();
      late final StreamSubscription<AudioFrame> subscription;
      final Completer<void> firstFrame = Completer<void>();
      subscription = session.frames.listen((_) {
        if (!firstFrame.isCompleted) {
          firstFrame.complete();
          subscription.pause();
        }
      });
      expect(() => session.frames.listen((_) {}), throwsStateError);

      final Future<void> running = session.start();
      await firstFrame.future;
      await session.abort().timeout(const Duration(seconds: 1));
      await running;
      await session.close().timeout(const Duration(seconds: 1));
      await subscription.cancel();
    },
  );

  test('paused status observer cannot hang resource close', () async {
    final AudioSourceSession session = await BufferedAudioSource(
      format: format,
      samples: Float32List.fromList(<double>[1, 2]),
      sourceId: 'memory',
      chunkFrameCount: 1,
    ).prepare();
    final StreamSubscription<AudioSessionStatus> statusObserver = session
        .statuses
        .listen((_) {});
    statusObserver.pause();

    await session.close().timeout(const Duration(seconds: 1));

    expect(session.status.state, AudioSessionState.closed);
    await statusObserver.cancel();
  });

  test('cancellation closes delivery with a stable failed state', () async {
    final BufferedAudioSource source = BufferedAudioSource(
      format: format,
      samples: Float32List.fromList(List<double>.filled(20, 0.1)),
      sourceId: 'memory',
      chunkFrameCount: 1,
    );
    final AudioSourceSession session = await source.prepare();
    final AudioCancellationController cancellation =
        AudioCancellationController();
    var count = 0;
    final StreamSubscription<AudioFrame> subscription = session.frames.listen((
      AudioFrame frame,
    ) {
      count += 1;
      if (count == 2) {
        cancellation.cancel();
      }
    });

    await expectLater(
      session.start(cancellationToken: cancellation.token),
      throwsA(isA<AudioCancelledException>()),
    );
    expect(session.status.state, AudioSessionState.failed);
    expect(session.status.failure?.code, 'buffered_source_cancelled');

    await subscription.cancel();
    await session.close();
  });
}
