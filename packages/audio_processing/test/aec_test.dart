// Portions adapted from Control Center's AEC tests.
// Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_processing/audio_processing.dart';
import 'package:test/test.dart';

void main() {
  group('AecDelayEstimator.rms', () {
    test('root-mean-square of a constant block equals its magnitude', () {
      expect(AecDelayEstimator.rms(_flat(0.5)), closeTo(0.5, 1e-6));
      expect(AecDelayEstimator.rms(_flat(-0.25)), closeTo(0.25, 1e-6));
      expect(AecDelayEstimator.rms(_flat(0)), 0);
    });

    test('empty input measures as silence', () {
      expect(AecDelayEstimator.rms(Float32List(0)), 0);
    });
  });

  group('AecDelayEstimator float32 calibration', () {
    test('locks onto a known 240 ms lead using the default silence floor', () {
      // The calibration the port demands: real float32 amplitudes, default
      // thresholds, a lag the estimator must recover exactly.
      final estimator = AecDelayEstimator();
      _feedDelayedEnvelope(estimator, delayBins: 24, seed: 31);

      final AecDelayEstimate? estimate = estimator.estimateSmoothed();

      expect(estimate, isNotNull);
      expect(estimate!.lagMs, closeTo(240, 10));
      expect(estimate.confidence, greaterThan(0.7));
      expect(estimator.hasLock(estimate), isTrue);
    });

    test('a PCM16-scale floor would reject the same float32 audio', () {
      // Regression guard for the scale trap: porting Control Center's literal
      // minNearStd of 1.0 asks for an envelope deviation 32768x louder than
      // full scale, so the estimator silently never measures and a downstream
      // fail-safe reports the canceller as ineffective rather than misbuilt.
      final estimator = AecDelayEstimator(minNearStd: 1);
      _feedDelayedEnvelope(estimator, delayBins: 24, seed: 31);

      expect(estimator.estimate(), isNull);
      expect(AecDelayEstimator.defaultMinNearStd, closeTo(3.0518e-5, 1e-9));
    });

    test('near-silence never reaches lock', () {
      final estimator = AecDelayEstimator();
      final math.Random random = math.Random(77);
      final List<double> far = _envelope(700, 41);
      for (var bin = 0; bin < far.length; bin += 1) {
        final int t = bin * 10;
        estimator.addFar(t, far[bin]);
        // Microphone floor noise well below the silence threshold.
        estimator.addNear(t, random.nextDouble() * 1e-6);
      }

      final AecDelayEstimate? estimate = estimator.estimateSmoothed();

      expect(estimate, isNull);
      expect(estimator.hasLock(estimate), isFalse);
    });
  });

  group('AecDelayEstimator.estimate', () {
    test('recovers a positive far-lead when the mic lags the loopback', () {
      final estimator = AecDelayEstimator();
      _feedDelayedEnvelope(estimator, delayBins: 8, seed: 1);

      final AecDelayEstimate? estimate = estimator.estimate();

      expect(estimate, isNotNull);
      expect(estimate!.lagMs, closeTo(80, 10));
      expect(estimate.confidence, greaterThan(0.7));
    });

    test('recovers a negative far-lead when the tap delivers late', () {
      final estimator = AecDelayEstimator();
      _feedDelayedEnvelope(estimator, delayBins: -12, seed: 3);

      final AecDelayEstimate? estimate = estimator.estimate();

      expect(estimate, isNotNull);
      expect(estimate!.lagMs, closeTo(-120, 10));
      expect(estimate.confidence, greaterThan(0.7));
    });

    test('recovers a 600 ms lead, beyond a narrower search range', () {
      final estimator = AecDelayEstimator();
      _feedDelayedEnvelope(estimator, delayBins: 60, seed: 11, bins: 800);

      final AecDelayEstimate? estimate = estimator.estimate();

      expect(estimate, isNotNull);
      expect(estimate!.lagMs, closeTo(600, 20));
    });

    test('returns null while still warming up', () {
      final estimator = AecDelayEstimator();
      for (var bin = 0; bin < 20; bin += 1) {
        estimator.addFar(bin * 10, 0.03);
        estimator.addNear(bin * 10, 0.015);
      }

      expect(estimator.estimate(), isNull);
    });

    test('uncorrelated channels yield low confidence', () {
      final estimator = AecDelayEstimator();
      final List<double> far = _envelope(700, 6);
      final List<double> near = _envelope(700, 9999);
      for (var bin = 0; bin < far.length; bin += 1) {
        estimator
          ..addFar(bin * 10, far[bin])
          ..addNear(bin * 10, near[bin]);
      }

      final AecDelayEstimate? estimate = estimator.estimate();

      expect(estimate, isNotNull);
      expect(estimate!.confidence, lessThan(0.5));
    });

    test('ignores negative timestamps and non-finite energies', () {
      final estimator = AecDelayEstimator();
      estimator
        ..addFar(-10, 0.5)
        ..addNear(-10, 0.5)
        ..addFar(0, double.nan)
        ..addNear(0, double.infinity);

      expect(estimator.estimate(), isNull);
    });

    test('reset clears history so a device change starts clean', () {
      final estimator = AecDelayEstimator();
      _feedDelayedEnvelope(estimator, delayBins: 8, seed: 1);
      expect(estimator.estimateSmoothed(), isNotNull);
      expect(estimator.recentEstimateCount, 1);

      estimator.reset();

      expect(estimator.estimate(), isNull);
      expect(estimator.recentEstimateCount, 0);
      expect(estimator.hasRepeatedSupport, isFalse);
    });

    test('rejects invalid configuration', () {
      expect(() => AecDelayEstimator(binMs: 0), throwsArgumentError);
      expect(() => AecDelayEstimator(windowMs: 0), throwsArgumentError);
      expect(() => AecDelayEstimator(maxLagMs: 0), throwsArgumentError);
      expect(() => AecDelayEstimator(minNearStd: -1), throwsArgumentError);
      expect(
        () => AecDelayEstimator(binMs: 10, windowMs: 5),
        throwsArgumentError,
      );
    });
  });

  group('AecDelayEstimator smoothing and lock tiers', () {
    AecDelayEstimate at(int lag) => AecDelayEstimate(lagMs: lag, confidence: 1);

    test('empty history has a zero median', () {
      expect(
        AecDelayEstimator.recencyWeightedMedianLagMs(
          const <AecDelayEstimate>[],
        ),
        0,
      );
    });

    test('a single newer outlier cannot swing the median', () {
      expect(
        AecDelayEstimator.recencyWeightedMedianLagMs(<AecDelayEstimate>[
          at(100),
          at(100),
          at(100),
          at(500),
        ]),
        100,
      );
    });

    test('the median tracks a genuinely drifting delay', () {
      expect(
        AecDelayEstimator.recencyWeightedMedianLagMs(<AecDelayEstimate>[
          at(100),
          at(100),
          at(200),
          at(200),
          at(200),
        ]),
        200,
      );
    });

    test('repeated agreement builds support and grants a lock', () {
      final estimator = AecDelayEstimator();
      _feedDelayedEnvelope(estimator, delayBins: 8, seed: 21);
      expect(estimator.hasRepeatedSupport, isFalse);

      AecDelayEstimate? last;
      for (var index = 0; index < 3; index += 1) {
        last = estimator.estimateSmoothed();
        expect(last, isNotNull);
      }

      expect(last!.lagMs, closeTo(80, 10));
      expect(estimator.hasRepeatedSupport, isTrue);
      // Second lock tier: agreement carries a measurement whose own confidence
      // would not clear the gate.
      expect(
        estimator.hasLock(const AecDelayEstimate(lagMs: 80, confidence: 0.1)),
        isTrue,
      );
    });

    test('a lone modest measurement does not lock', () {
      final estimator = AecDelayEstimator();

      expect(
        estimator.hasLock(const AecDelayEstimate(lagMs: 80, confidence: 0.4)),
        isFalse,
      );
      expect(
        estimator.hasLock(const AecDelayEstimate(lagMs: 80, confidence: 0.6)),
        isTrue,
      );
      expect(estimator.hasLock(null), isFalse);
    });
  });

  group('float32 and PCM16 conversion', () {
    test('round-trips within one quantization step', () {
      final Float32List input = Float32List.fromList(<double>[
        0,
        0.5,
        -0.5,
        0.999,
        -0.999,
      ]);

      final Float32List output = pcm16ToFloat(floatToPcm16(input));

      for (var index = 0; index < input.length; index += 1) {
        expect(output[index], closeTo(input[index], 1 / 32767));
      }
    });

    test('clamps out-of-range input instead of wrapping it', () {
      final Int16List encoded = floatToPcm16(
        Float32List.fromList(<double>[2, -2, double.nan]),
      );

      expect(encoded[0], 32767);
      expect(encoded[1], -32768);
      expect(encoded[2], 0);
    });

    test('decoding stays inside the nominal range', () {
      final Float32List decoded = pcm16ToFloat(
        Int16List.fromList(<int>[32767, -32768]),
      );

      expect(decoded[0], closeTo(1, 1e-6));
      expect(decoded[1], -1);
    });
  });

  group('AecBlockAccumulator', () {
    test('emits exact blocks and carries the remainder across calls', () {
      final accumulator = AecBlockAccumulator();
      final List<Int16List> blocks = <Int16List>[];

      accumulator.add(_ramp(100), blocks.add);
      expect(blocks, isEmpty);
      expect(accumulator.pendingFrameCount, 100);

      accumulator.add(_ramp(100), blocks.add);
      expect(blocks, hasLength(1));
      expect(blocks.single, hasLength(kAecBlockFrames));
      expect(accumulator.pendingFrameCount, 40);
    });

    test('preserves sample order across ragged chunk boundaries', () {
      final accumulator = AecBlockAccumulator();
      final List<int> emitted = <int>[];
      final Float32List source = _ramp(kAecBlockFrames * 3);

      // Deliberately awkward chunk sizes, including one larger than a block.
      var offset = 0;
      for (final int size in <int>[7, 1, 200, 33, 150, 89]) {
        final int end = math.min(offset + size, source.length);
        accumulator.add(
          Float32List.sublistView(source, offset, end),
          (Int16List block) => emitted.addAll(block),
        );
        offset = end;
      }

      expect(emitted, hasLength(kAecBlockFrames * 3));
      final Int16List expected = floatToPcm16(source);
      expect(emitted, orderedEquals(expected));
      expect(accumulator.pendingFrameCount, 0);
    });

    test('handles a chunk that exactly fills several blocks', () {
      final accumulator = AecBlockAccumulator();
      final List<Int16List> blocks = <Int16List>[];

      accumulator.add(_ramp(kAecBlockFrames * 4), blocks.add);

      expect(blocks, hasLength(4));
      expect(accumulator.pendingFrameCount, 0);
    });

    test('drain pads the tail with silence and empties the buffer', () {
      final accumulator = AecBlockAccumulator();
      accumulator.add(_flat(0.5, frames: 40), (Int16List _) {});

      final Int16List? tail = accumulator.drain();

      expect(tail, isNotNull);
      expect(tail!, hasLength(kAecBlockFrames));
      expect(tail.sublist(0, 40).every((int s) => s > 0), isTrue);
      expect(tail.sublist(40).every((int s) => s == 0), isTrue);
      expect(accumulator.pendingFrameCount, 0);
      expect(accumulator.drain(), isNull);
    });

    test('reset discards buffered samples', () {
      final accumulator = AecBlockAccumulator()
        ..add(_ramp(100), (Int16List _) {});

      accumulator.reset();

      expect(accumulator.pendingFrameCount, 0);
      expect(accumulator.drain(), isNull);
    });

    test('rejects a non-positive block size', () {
      expect(() => AecBlockAccumulator(blockFrames: 0), throwsArgumentError);
    });
  });

  group('waveform utilities', () {
    test('mixes tracks of differing lengths to the longest', () {
      final Float32List mixed = mixTracksToMono(<Float32List>[
        Float32List.fromList(<double>[0.5, 0.5, 0.5, 0.5]),
        Float32List.fromList(<double>[0.25, 0.25]),
      ]);

      expect(mixed, hasLength(4));
      expect(mixed[0], closeTo(0.75, 1e-6));
      expect(mixed[1], closeTo(0.75, 1e-6));
      expect(mixed[2], closeTo(0.5, 1e-6));
      expect(mixed[3], closeTo(0.5, 1e-6));
    });

    test('hard-clips a summed overflow', () {
      final Float32List mixed = mixTracksToMono(<Float32List>[
        Float32List.fromList(<double>[0.8, -0.8]),
        Float32List.fromList(<double>[0.8, -0.8]),
      ]);

      expect(mixed[0], 1);
      expect(mixed[1], -1);
    });

    test('skips empty tracks and returns empty when nothing is present', () {
      expect(mixTracksToMono(<Float32List>[]), isEmpty);
      expect(mixTracksToMono(<Float32List>[Float32List(0)]), isEmpty);

      final Float32List single = Float32List.fromList(<double>[0.1, 0.2]);
      expect(
        mixTracksToMono(<Float32List>[Float32List(0), single]),
        orderedEquals(single),
      );
    });

    test('peak buckets normalize so the loudest bucket is one', () {
      final Float32List samples = Float32List.fromList(<double>[
        0.1, -0.1, //
        0.4, -0.2, //
        0.05, 0.05, //
      ]);

      final List<double> buckets = peakBuckets(samples, 3);

      expect(buckets, hasLength(3));
      expect(buckets[0], closeTo(0.25, 1e-6));
      expect(buckets[1], 1);
      expect(buckets[2], closeTo(0.125, 1e-6));
    });

    test('peak buckets guarantee one sample per bucket when oversampled', () {
      final List<double> buckets = peakBuckets(
        Float32List.fromList(<double>[0.5, 1]),
        4,
      );

      expect(buckets, hasLength(4));
      expect(buckets.every((double value) => value >= 0 && value <= 1), isTrue);
    });

    test('peak buckets reject empty input or a non-positive count', () {
      expect(peakBuckets(Float32List(0), 8), isEmpty);
      expect(peakBuckets(Float32List.fromList(<double>[1]), 0), isEmpty);
    });

    test('a silent track normalizes to all zeroes rather than dividing', () {
      expect(peakBuckets(_flat(0, frames: 16), 4), everyElement(0));
    });
  });
}

/// Envelope values on the float32 scale: a quiet-to-moderate speech range.
List<double> _envelope(int bins, int seed) {
  final math.Random random = math.Random(seed);
  return List<double>.generate(
    bins,
    (_) => 0.006 + (random.nextDouble() * 0.122),
  );
}

/// Feeds an estimator a far envelope plus a near copy displaced by
/// [delayBins]. A positive value means the far end leads.
void _feedDelayedEnvelope(
  AecDelayEstimator estimator, {
  required int delayBins,
  required int seed,
  int bins = 700,
}) {
  final List<double> far = _envelope(bins, seed);
  final math.Random random = math.Random(seed + 1);
  for (var bin = 0; bin < far.length; bin += 1) {
    final int t = bin * 10;
    estimator.addFar(t, far[bin]);
    final int source = bin - delayBins;
    final double floor = random.nextDouble() * 0.0015;
    estimator.addNear(
      t,
      source >= 0 && source < far.length ? (far[source] * 0.5) + floor : floor,
    );
  }
}

Float32List _flat(double amplitude, {int frames = 160}) =>
    Float32List(frames)..fillRange(0, frames, amplitude);

Float32List _ramp(int frames) => Float32List(frames)
  ..setRange(
    0,
    frames,
    List<double>.generate(frames, (int i) => ((i % 200) - 100) / 100),
  );
