import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_aec/audio_aec.dart';
import 'package:audio_core/audio_core.dart';
import 'package:test/test.dart';

import 'fakes.dart';

final AudioFormat _format = AudioFormat(sampleRate: 16000, channels: 1);

/// One quantization step of the float32 -> int16 -> float32 round trip.
const double _quantum = 1 / 32767;

void main() {
  group('passthrough (no processor)', () {
    test('reproduces the microphone samples exactly', () async {
      final _Rig rig = _Rig(withProcessor: false);
      await rig.start();
      final Float32List chunk = tone(400, 0.42);

      await rig.feed(nearChunk: chunk);
      rig.nearSession.finish();
      await tick();

      expect(rig.session.isActive, isFalse);
      expect(rig.emittedSamples, chunk.toList());
      expect(rig.bindings.calls, isEmpty);
    });

    test(
      'never prepares the far source: there is nothing to reference',
      () async {
        final _Rig rig = _Rig(withProcessor: false);
        await rig.start();

        expect(rig.far.session, isNull);
        expect(rig.near.session, isNotNull);
      },
    );

    test('metrics are empty and the delay never locks', () async {
      final _Rig rig = _Rig(withProcessor: false);
      await rig.start();

      await rig.feed(nearChunk: tone(160, 0.3));

      expect(rig.session.metrics().erle, isNull);
      expect(rig.session.isLocked, isFalse);
      expect(rig.session.micBufferMs, 0);
    });

    test(
      'emitted frames carry this session\'s identity, not the source\'s',
      () async {
        final _Rig rig = _Rig(withProcessor: false);
        await rig.start();

        await rig.feed(nearChunk: tone(160, 0.3));

        final AudioFrame frame = rig.emitted.single;
        expect(frame.sourceId, 'mic.aec');
        expect(frame.clockId, 'mic.clock.aec');
        expect(frame.sequence, 0);
        expect(frame.sampleOffset, 0);
      },
    );

    test(
      'AecMicFilter.passthrough is the same thing without a far source',
      () async {
        final ManualAudioSource near = ManualAudioSource(format: _format);
        final AecMicFilter filter = AecMicFilter.passthrough(near: near);
        final AecMicFilterSession session = await filter.prepare();
        final List<AudioFrame> emitted = <AudioFrame>[];
        session.frames.listen(emitted.add);
        await session.start();

        near.session!.push(tone(160, 0.25));
        await tick();

        expect(session.isActive, isFalse);
        expect(emitted.single.samples, tone(160, 0.25));
        await session.close();
      },
    );
  });

  group('fail-safe passthrough before lock', () {
    test('adds no buffering and feeds a zero delay hint', () async {
      final _Rig rig = _Rig();
      await rig.start();

      for (var index = 0; index < 20; index += 1) {
        await rig.feed(farChunk: tone(160, 0.2), nearChunk: tone(160, 0.3));
      }

      expect(rig.session.isLocked, isFalse);
      expect(rig.session.micBufferMs, 0);
      expect(rig.bindings.streamDelays, everyElement(0));
      // No buffering means block-for-block output: never worse than no AEC.
      expect(rig.bindings.streamDelays.length, 20);
      expect(rig.emittedSamples.length, 20 * 160);
    });

    test('still runs audio through the engine while unlocked', () async {
      final _Rig rig = _Rig();
      await rig.start();

      await rig.feed(farChunk: tone(160, 0.2), nearChunk: tone(160, 0.5));

      expect(rig.bindings.captureBlocks, hasLength(1));
      expect(rig.bindings.reverseBlocks, hasLength(1));
    });
  });

  group('echo cancellation', () {
    test('removes an injected echo, within one quantization step', () async {
      final _Rig rig = _Rig();
      await rig.start();
      final Float32List speech = tone(160, 0.3);
      final Float32List echo = tone(160, 0.2);

      for (var index = 0; index < 5; index += 1) {
        await rig.feed(farChunk: echo, nearChunk: mix(speech, echo));
      }
      rig.nearSession.finish();
      await tick();

      final List<double> emitted = rig.emittedSamples;
      expect(emitted, hasLength(5 * 160));
      for (var index = 0; index < emitted.length; index += 1) {
        expect(
          emitted[index],
          closeTo(speech[index % 160], 2 * _quantum),
          reason: 'sample $index survived as echo',
        );
      }
    });
  });

  group('delay lock', () {
    test('drives the measured lag into stream_delay_ms', () async {
      final _Rig rig = _Rig();
      await rig.start();

      await _feedCorrelated(rig, lagBins: 24);

      expect(rig.session.isLocked, isTrue);
      expect(rig.session.lastDelayEstimate?.lagMs, 240);
      // A 240 ms lead already exceeds the 80 ms target, so no mic buffering is
      // needed and the measured lag reaches the engine unchanged.
      expect(rig.session.micBufferMs, 0);
      expect(rig.session.streamDelayMs, 240);
      expect(rig.bindings.streamDelays.last, 240);
      expect(rig.bindings.streamDelays.toSet(), <int>{0, 240});
    });

    test('buffers the mic so the far end leads by the 80 ms target', () async {
      final _Rig rig = _Rig();
      await rig.start();

      await _feedCorrelated(rig, lagBins: 3);

      expect(rig.session.isLocked, isTrue);
      expect(rig.session.lastDelayEstimate?.lagMs, 30);
      // 30 ms measured + 50 ms of mic buffering = the 80 ms target lead.
      expect(rig.session.micBufferMs, 50);
      expect(rig.session.streamDelayMs, AecMicFilter.targetLeadMs);
      expect(rig.bindings.streamDelays.last, AecMicFilter.targetLeadMs);
    });

    test('the mic buffer holds back exactly its depth in blocks', () async {
      final _Rig rig = _Rig();
      await rig.start();

      await _feedCorrelated(rig, lagBins: 3);
      final int processedBeforeFinish = rig.bindings.captureBlocks.length;
      final int pushedBlocks = rig.nearSession.pushedFrameCount;

      expect(processedBeforeFinish, pushedBlocks - 5);

      rig.nearSession.finish();
      await tick();

      // End of stream flushes the buffer: no audio is lost to the lock.
      expect(rig.bindings.captureBlocks.length, pushedBlocks);
    });

    test('a confident lag never exceeds the engine delay clamp', () async {
      final _Rig rig = _Rig();
      await rig.start();

      await _feedCorrelated(rig, lagBins: 70);

      expect(rig.session.isLocked, isTrue);
      expect(rig.session.lastDelayEstimate?.lagMs, 700);
      expect(rig.session.streamDelayMs, AecMicFilter.maxStreamDelayMs);
    });
  });

  group('reference-availability gate', () {
    test(
      'zero-pads the reference when the loopback stalls mid-stream',
      () async {
        final _Rig rig = _Rig();
        await rig.start();
        final Float32List echo = tone(160, 0.2);
        final Float32List speech = tone(160, 0.3);

        for (var index = 0; index < 30; index += 1) {
          await rig.feed(farChunk: echo, nearChunk: mix(speech, echo));
        }
        expect(rig.session.referenceBlocksMatched, 30);
        expect(rig.session.referenceBlocksZeroPadded, 0);

        // The loopback stalls; the mic keeps running.
        for (var index = 0; index < 12; index += 1) {
          await rig.feed(nearChunk: mix(speech, echo));
        }

        expect(rig.session.referenceBlocksMatched, 30);
        expect(rig.session.referenceBlocksZeroPadded, 12);
      },
    );

    test('cancels against silence, not a stale echo', () async {
      final _Rig rig = _Rig();
      await rig.start();
      final Float32List echo = tone(160, 0.2);
      final Float32List microphone = mix(tone(160, 0.3), echo);

      await rig.feed(farChunk: echo, nearChunk: microphone);
      final int emittedBeforeStall = rig.emittedSamples.length;
      await rig.feed(nearChunk: microphone);

      // A stale-echo implementation would subtract the previous reference and
      // return the speech; zero-padding returns the microphone untouched.
      final List<double> stalled = rig.emittedSamples.sublist(
        emittedBeforeStall,
      );
      expect(stalled, hasLength(160));
      for (var index = 0; index < stalled.length; index += 1) {
        expect(stalled[index], closeTo(microphone[index], 2 * _quantum));
      }
      expect(rig.bindings.reverseBlocks.last.every((int v) => v == 0), isTrue);
    });

    test(
      'keeps render and capture block counts equal through a stall',
      () async {
        final _Rig rig = _Rig();
        await rig.start();

        for (var index = 0; index < 6; index += 1) {
          await rig.feed(farChunk: tone(160, 0.2), nearChunk: tone(160, 0.3));
        }
        for (var index = 0; index < 4; index += 1) {
          await rig.feed(nearChunk: tone(160, 0.3));
        }

        expect(
          rig.bindings.reverseBlocks.length,
          rig.bindings.captureBlocks.length,
        );
        expect(rig.bindings.pendingReferenceCount, 0);
      },
    );
  });

  group('block alignment', () {
    test('chops odd chunk sizes into exact 160-sample blocks', () async {
      final _Rig rig = _Rig();
      await rig.start();
      const List<int> chunkSizes = <int>[37, 211, 160, 1, 999, 512, 3];
      var total = 0;

      for (final int size in chunkSizes) {
        total += size;
        await rig.feed(farChunk: tone(size, 0.2), nearChunk: tone(size, 0.3));
      }

      expect(rig.bindings.frameCounts, everyElement(160));
      expect(total, 1923);
      expect(rig.bindings.captureBlocks.length, total ~/ 160);
    });

    test('drains the trailing partial block at end of stream', () async {
      final _Rig rig = _Rig();
      await rig.start();

      await rig.feed(farChunk: tone(400, 0.2), nearChunk: tone(400, 0.3));
      expect(rig.emittedSamples.length, 320);

      rig.nearSession.finish();
      await tick();

      // 400 samples is two whole blocks plus 80; the remainder is padded once,
      // at the only moment padding cannot desynchronize the timeline.
      expect(rig.emittedSamples.length, 480);
      expect(rig.bindings.frameCounts, everyElement(160));
    });

    test('loses no audio across chunk seams', () async {
      final _Rig rig = _Rig();
      await rig.start();
      final math.Random random = math.Random(11);
      final List<double> pushed = <double>[];

      for (var index = 0; index < 8; index += 1) {
        final int size = 1 + random.nextInt(400);
        final Float32List chunk = tone(size, 0.25);
        pushed.addAll(chunk);
        await rig.feed(nearChunk: chunk);
      }
      rig.nearSession.finish();
      await tick();

      final List<double> emitted = rig.emittedSamples;
      expect(emitted.length, greaterThanOrEqualTo(pushed.length));
      for (var index = 0; index < pushed.length; index += 1) {
        expect(emitted[index], closeTo(pushed[index], 2 * _quantum));
      }
    });

    test('emitted frame metadata is a continuous timeline', () async {
      final _Rig rig = _Rig();
      await rig.start();

      for (var index = 0; index < 3; index += 1) {
        await rig.feed(farChunk: tone(160, 0.2), nearChunk: tone(160, 0.3));
      }

      var expectedOffset = 0;
      for (var index = 0; index < rig.emitted.length; index += 1) {
        final AudioFrame frame = rig.emitted[index];
        expect(frame.sequence, index);
        expect(frame.sampleOffset, expectedOffset);
        expect(frame.timestamp, _format.durationForFrames(expectedOffset));
        expectedOffset += frame.frameCount;
      }
    });
  });

  group('discontinuity', () {
    test(
      'propagates a capture discontinuity to the next emitted frame',
      () async {
        final _Rig rig = _Rig();
        await rig.start();

        rig.now += 10;
        rig.nearSession.push(
          tone(160, 0.3),
          discontinuity: AudioDiscontinuity(
            reason: AudioDiscontinuityReason.droppedFrames,
            droppedFrameCount: 2,
          ),
        );
        await tick();

        expect(
          rig.emitted.single.discontinuity?.reason,
          AudioDiscontinuityReason.droppedFrames,
        );
      },
    );

    test(
      'a source restart drops the lock back to fail-safe passthrough',
      () async {
        final _Rig rig = _Rig();
        await rig.start();
        await _feedCorrelated(rig, lagBins: 3);
        expect(rig.session.isLocked, isTrue);

        rig.now += 10;
        rig.nearSession.push(
          tone(160, 0.3),
          discontinuity: AudioDiscontinuity(
            reason: AudioDiscontinuityReason.sourceRestart,
          ),
        );
        await tick();

        expect(rig.session.isLocked, isFalse);
        expect(rig.session.micBufferMs, 0);
        expect(rig.session.streamDelayMs, 0);
      },
    );
  });

  group('session contract', () {
    test(
      'rejects pause: a realtime capture must never be back-pressured',
      () async {
        final _Rig rig = _Rig();
        await rig.start();

        expect(rig.session.capabilities.supportsPause, isFalse);
        await expectLater(rig.session.pause(), throwsUnsupportedError);
        await expectLater(rig.session.resume(), throwsUnsupportedError);
      },
    );

    test('the frame subscription refuses to pause', () async {
      final ManualAudioSource near = ManualAudioSource(format: _format);
      final AecMicFilter filter = AecMicFilter.passthrough(near: near);
      final AecMicFilterSession session = await filter.prepare();
      final subscription = session.frames.listen((AudioFrame _) {});

      expect(subscription.pause, throwsUnsupportedError);
      await subscription.cancel();
      await session.close();
    });

    test(
      'reports the microphone format and realtime characteristics',
      () async {
        final _Rig rig = _Rig();
        await rig.start();

        expect(rig.session.format, _format);
        expect(rig.session.capabilities.isRealtime, isTrue);
      },
    );

    test('one filter drives exactly one session', () async {
      final _Rig rig = _Rig();
      await rig.start();

      await expectLater(rig.filter.prepare(), throwsStateError);
    });

    test('starts the reference before the capture', () async {
      final _Rig rig = _Rig();
      await rig.start();

      expect(rig.farSession.isStarted, isTrue);
      expect(rig.nearSession.isStarted, isTrue);
    });

    test(
      'reaches the active state and then finishes with the capture',
      () async {
        final _Rig rig = _Rig();
        await rig.start();
        expect(rig.session.status.state, AudioSessionState.active);

        rig.nearSession.finish();
        await tick();

        expect(rig.session.status.state, AudioSessionState.finished);
      },
    );

    test('honours a cancellation token at prepare', () async {
      final AudioCancellationController controller =
          AudioCancellationController()..cancel();
      final AecMicFilter filter = AecMicFilter.passthrough(
        near: ManualAudioSource(format: _format),
      );

      await expectLater(
        filter.prepare(cancellationToken: controller.token),
        throwsA(isA<AudioCancelledException>()),
      );
    });
  });

  group('format validation', () {
    test('rejects a sample rate the engine was not created for', () async {
      final AudioFormat wrong = AudioFormat(sampleRate: 48000, channels: 1);
      final bindings = FakeAecBindings();
      final AecMicFilter filter = AecMicFilter(
        near: ManualAudioSource(format: wrong),
        far: ManualAudioSource(format: wrong),
        processor: AecProcessor.fromBindings(bindings),
      );

      await expectLater(filter.prepare(), throwsA(isA<ArgumentError>()));
      expect(
        bindings.destroyCount,
        1,
        reason: 'a failed one-shot prepare has no session to own the engine',
      );
    });

    test('rejects a stereo capture', () async {
      final AudioFormat stereo = AudioFormat(sampleRate: 16000, channels: 2);
      final AecMicFilter filter = AecMicFilter(
        near: ManualAudioSource(format: stereo),
        far: ManualAudioSource(format: stereo),
        processor: AecProcessor.fromBindings(FakeAecBindings()),
      );

      await expectLater(filter.prepare(), throwsA(isA<ArgumentError>()));
    });

    test('rejects a reference that disagrees with the capture', () async {
      final AecMicFilter filter = AecMicFilter(
        near: ManualAudioSource(format: _format),
        far: ManualAudioSource(
          format: AudioFormat(sampleRate: 16000, channels: 2),
        ),
        processor: AecProcessor.fromBindings(FakeAecBindings()),
      );

      await expectLater(filter.prepare(), throwsA(isA<ArgumentError>()));
    });

    test('requires a far source whenever a processor is supplied', () {
      expect(
        () => AecMicFilter(
          near: ManualAudioSource(format: _format),
          processor: AecProcessor.fromBindings(FakeAecBindings()),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('disposal ordering', () {
    test(
      'destroys the engine only after both captures are cancelled',
      () async {
        final _Rig rig = _Rig();
        await rig.start();
        for (var index = 0; index < 4; index += 1) {
          await rig.feed(farChunk: tone(160, 0.2), nearChunk: tone(160, 0.3));
        }

        await rig.session.close();

        expect(rig.bindings.calls.last, 'destroy');
        expect(rig.bindings.destroyCount, 1);
        expect(rig.session.status.state, AudioSessionState.closed);
      },
    );

    test(
      'a frame arriving after close never reaches the freed handle',
      () async {
        final _Rig rig = _Rig();
        await rig.start();
        await rig.feed(farChunk: tone(160, 0.2), nearChunk: tone(160, 0.3));

        await rig.session.close();
        rig.nearSession.push(tone(160, 0.3));
        await tick();

        expect(rig.bindings.calls.last, 'destroy');
      },
    );

    test('close is idempotent', () async {
      final _Rig rig = _Rig();
      await rig.start();

      await rig.session.close();
      await rig.session.close();

      expect(rig.bindings.destroyCount, 1);
    });

    test('closes the upstream capture sessions too', () async {
      final _Rig rig = _Rig();
      await rig.start();

      await rig.session.close();

      expect(rig.nearSession.status.state, AudioSessionState.closed);
      expect(rig.farSession.status.state, AudioSessionState.closed);
    });
  });
}

/// Feeds correlated envelopes where the far end leads the near end by
/// [lagBins] 10 ms bins, long enough for the estimator to clear its warm-up.
Future<void> _feedCorrelated(
  _Rig rig, {
  required int lagBins,
  int ticks = 600,
  int seed = 7,
}) async {
  final math.Random random = math.Random(seed);
  final List<double> envelope = List<double>.generate(
    ticks + lagBins + 1,
    (int _) => 0.05 + random.nextDouble() * 0.45,
  );
  for (var index = 0; index < ticks; index += 1) {
    // The microphone hears now what the loopback played [lagBins] bins ago.
    final double nearAmplitude = index >= lagBins
        ? envelope[index - lagBins]
        : 0.02;
    await rig.feed(
      farChunk: tone(160, envelope[index]),
      nearChunk: tone(160, nearAmplitude),
    );
  }
}

final class _Rig {
  _Rig({bool withProcessor = true, void Function(String message)? log}) {
    near = ManualAudioSource(
      format: _format,
      sourceId: 'mic',
      clockId: 'mic.clock',
    );
    far = ManualAudioSource(
      format: _format,
      sourceId: 'loopback',
      clockId: 'loopback.clock',
    );
    processor = withProcessor ? AecProcessor.fromBindings(bindings) : null;
    filter = AecMicFilter(
      near: near,
      far: far,
      processor: processor,
      clockNow: () => now,
      log: log,
    );
  }

  final FakeAecBindings bindings = FakeAecBindings();
  final List<AudioFrame> emitted = <AudioFrame>[];
  int now = 0;
  AecProcessor? processor;
  late final ManualAudioSource near;
  late final ManualAudioSource far;
  late final AecMicFilter filter;
  late final AecMicFilterSession session;

  ManualAudioSourceSession get nearSession => near.session!;
  ManualAudioSourceSession get farSession => far.session!;

  List<double> get emittedSamples => <double>[
    for (final AudioFrame frame in emitted) ...frame.samples,
  ];

  Future<void> start() async {
    session = await filter.prepare();
    session.frames.listen(emitted.add);
    await session.start();
  }

  Future<void> feed({
    Float32List? nearChunk,
    Float32List? farChunk,
    int advanceMs = 10,
  }) async {
    now += advanceMs;
    if (farChunk != null) {
      farSession.push(farChunk);
    }
    if (nearChunk != null) {
      nearSession.push(nearChunk);
    }
    await tick();
  }
}
