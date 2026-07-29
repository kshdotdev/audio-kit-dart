// Adapted from Control Center's `aec_delay_estimator.dart`.
// Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.
//
// Adaptation notes: the original operates on PCM16 sample magnitudes; this port
// is float32-native ([-1, 1]), so every amplitude-scale constant is rescaled by
// 1/32768. See `defaultMinNearStd`.

import 'dart:math' as math;
import 'dart:typed_data';

/// Result of an [AecDelayEstimator] measurement.
final class AecDelayEstimate {
  /// Creates an estimate with the measured [lagMs] and its [confidence].
  const AecDelayEstimate({required this.lagMs, required this.confidence});

  /// How far the far-end (loopback) leads the near-end (mic) on the shared
  /// submission timeline, in milliseconds.
  ///
  /// Positive means the loopback reference arrives before the mic echo it
  /// should cancel, which is what an echo canceller wants and can be fed
  /// straight to a stream-delay parameter. Negative means the mic echo arrives
  /// first because the system capture is delivering late; a canceller cannot
  /// use a negative delay, so the mic must be buffered by `|lagMs|` plus a
  /// margin to restore a positive lead.
  final int lagMs;

  /// Peak normalized cross-correlation at [lagMs], clamped to `[0, 1]`.
  ///
  /// Higher values mean a more trustworthy alignment. Callers gate locking on
  /// a minimum; see [AecDelayEstimator.hasLock].
  final double confidence;

  @override
  String toString() =>
      'AecDelayEstimate(lagMs: $lagMs, confidence: '
      '${confidence.toStringAsFixed(3)})';
}

/// Estimates the offset between a system-loopback ("far") and a microphone
/// ("near") capture by cross-correlating their short-time energy envelopes on
/// one shared clock.
///
/// The two captures are independent operating-system streams with drifting
/// clocks and a delivery offset that depends on the user's audio hardware, so a
/// hardcoded delay is correct on exactly one machine. This measures the real
/// offset from the audio itself: remote speech bleeds into the microphone a
/// fixed delay after it plays out through the loopback, and that delay is the
/// lag at which the two envelopes correlate.
///
/// Correlating envelopes rather than raw samples is deliberate. An acoustic
/// echo is an attenuated, room-colored copy of the loopback, so the waveforms
/// correlate poorly while their loudness over time aligns tightly. Pearson
/// correlation makes the result level- and gain-invariant.
///
/// Feed it with [addFar] and [addNear] using timestamps from a single clock,
/// then read [estimateSmoothed] and [hasLock]. State is bounded: envelopes are
/// pruned to the analysis window plus lag headroom on every write.
final class AecDelayEstimator {
  /// Creates an estimator.
  ///
  /// Defaults are 10 ms envelope bins, a 2.5 s analysis window, a ±800 ms
  /// search range, and the float32 near-silence floor [defaultMinNearStd].
  ///
  /// The ±800 ms range covers high-latency paths — VPN, conference bridges,
  /// Bluetooth output — where the loopback can lead the microphone echo by well
  /// over 400 ms. Searching too tight a range there silently locks onto a
  /// truncated, wrong lag.
  factory AecDelayEstimator({
    int binMs = 10,
    int windowMs = 2500,
    int maxLagMs = 800,
    double minNearStd = defaultMinNearStd,
  }) {
    if (binMs <= 0) {
      throw ArgumentError.value(binMs, 'binMs', 'Must be positive.');
    }
    if (windowMs <= 0) {
      throw ArgumentError.value(windowMs, 'windowMs', 'Must be positive.');
    }
    if (maxLagMs <= 0) {
      throw ArgumentError.value(maxLagMs, 'maxLagMs', 'Must be positive.');
    }
    if (windowMs < binMs) {
      throw ArgumentError.value(
        windowMs,
        'windowMs',
        'Must be at least one bin wide.',
      );
    }
    if (!minNearStd.isFinite || minNearStd < 0) {
      throw ArgumentError.value(
        minNearStd,
        'minNearStd',
        'Must be finite and non-negative.',
      );
    }
    return AecDelayEstimator._(
      binMs: binMs,
      windowMs: windowMs,
      maxLagMs: maxLagMs,
      minNearStd: minNearStd,
    );
  }

  AecDelayEstimator._({
    required this.binMs,
    required this.windowMs,
    required this.maxLagMs,
    required this.minNearStd,
  }) : _binCount = windowMs ~/ binMs,
       _maxLagBins = maxLagMs ~/ binMs;

  /// Near-silence floor for float32 PCM, expressed on the `[-1, 1]` scale.
  ///
  /// The Control Center original defaults this to `1.0` because its envelopes
  /// carry PCM16 sample magnitudes, where full scale is 32768. Audio Kit frames
  /// are float32, so the same physical threshold is `1 / 32768`. Porting the
  /// literal `1.0` would demand an envelope deviation 32768× louder than full
  /// scale, the estimator would never return a measurement, and a fail-safe
  /// passthrough downstream would report the canceller as present but
  /// ineffective rather than as broken.
  static const double defaultMinNearStd = 1.0 / 32768;

  /// Confidence at or above which a single measurement is trustworthy on its
  /// own, forming the first of two lock tiers. See [hasLock].
  static const double defaultLockConfidence = 0.55;

  /// Envelope sampling resolution. One 10 ms processing block is one bin.
  final int binMs;

  /// Correlation analysis window: how much recent audio is compared.
  final int windowMs;

  /// Maximum absolute lag searched in each direction.
  final int maxLagMs;

  /// Minimum near-channel envelope standard deviation required to attempt a
  /// measurement. Below it the microphone is effectively silent and there is
  /// nothing to align.
  final double minNearStd;

  final int _binCount;
  final int _maxLagBins;

  // Sparse envelopes keyed by absolute bin index, pruned on every write.
  final Map<int, double> _far = <int, double>{};
  final Map<int, double> _near = <int, double>{};
  int _latestBin = -1;
  int _firstBin = -1;

  final List<AecDelayEstimate> _recent = <AecDelayEstimate>[];
  static const int _recentCap = 7;

  /// How far a recent estimate may sit from the cluster centre and still count
  /// as support for the repeated-agreement lock tier.
  static const int _supportToleranceMs = 80;

  /// Root-mean-square amplitude of one mono float32 [samples] block, suitable
  /// as an envelope sample for [addFar] or [addNear].
  static double rms(Float32List samples) {
    final int count = samples.length;
    if (count == 0) {
      return 0;
    }
    var sumOfSquares = 0.0;
    for (var index = 0; index < count; index += 1) {
      final double sample = samples[index];
      sumOfSquares += sample * sample;
    }
    return math.sqrt(sumOfSquares / count);
  }

  /// Records far-end (loopback) energy [rms] stamped at shared-clock [tMs].
  void addFar(int tMs, double rms) => _put(_far, tMs, rms);

  /// Records near-end (microphone) energy [rms] stamped at shared-clock [tMs].
  void addNear(int tMs, double rms) => _put(_near, tMs, rms);

  void _put(Map<int, double> envelope, int tMs, double rms) {
    if (tMs < 0 || !rms.isFinite) {
      return;
    }
    final int bin = tMs ~/ binMs;
    // Keep the loudest sample seen in a bin: this is an envelope peak.
    final double? previous = envelope[bin];
    if (previous == null || rms > previous) {
      envelope[bin] = rms;
    }
    if (_firstBin < 0) {
      _firstBin = bin;
    }
    if (bin > _latestBin) {
      _latestBin = bin;
      _prune();
    }
  }

  void _prune() {
    final int keep = _binCount + (2 * _maxLagBins) + 5;
    final int cutoff = _latestBin - keep;
    if (cutoff <= 0) {
      return;
    }
    _far.removeWhere((int bin, _) => bin < cutoff);
    _near.removeWhere((int bin, _) => bin < cutoff);
    if (_firstBin < cutoff) {
      _firstBin = cutoff;
    }
  }

  /// Cross-correlates the two envelopes and returns the best lag with its
  /// confidence, or `null` while warming up or when the microphone is silent.
  AecDelayEstimate? estimate() {
    if (_latestBin < 0 || _firstBin < 0) {
      return null;
    }
    // Far-side headroom of maxLag is needed on both sides of the analysis
    // window so every candidate lag indexes real data rather than absent bins.
    final int hi = _latestBin - _maxLagBins;
    final int lo = hi - _binCount + 1;
    if (lo - _maxLagBins < _firstBin) {
      return null; // Still warming up.
    }

    final Float64List near = Float64List(_binCount);
    var nearMean = 0.0;
    for (var index = 0; index < _binCount; index += 1) {
      final double energy = _near[lo + index] ?? 0.0;
      near[index] = energy;
      nearMean += energy;
    }
    nearMean /= _binCount;
    var nearNormSq = 0.0;
    for (var index = 0; index < _binCount; index += 1) {
      near[index] -= nearMean;
      nearNormSq += near[index] * near[index];
    }
    final double nearStd = math.sqrt(nearNormSq / _binCount);
    if (nearStd < minNearStd) {
      return null; // Microphone effectively silent; nothing to align.
    }

    var bestCorrelation = -2.0;
    var bestLag = 0;
    for (var lag = -_maxLagBins; lag <= _maxLagBins; lag += 1) {
      var farMean = 0.0;
      for (var index = 0; index < _binCount; index += 1) {
        farMean += _far[lo + index - lag] ?? 0.0;
      }
      farMean /= _binCount;
      var dot = 0.0;
      var farNormSq = 0.0;
      for (var index = 0; index < _binCount; index += 1) {
        final double far = (_far[lo + index - lag] ?? 0.0) - farMean;
        dot += near[index] * far;
        farNormSq += far * far;
      }
      if (farNormSq <= 0) {
        continue;
      }
      final double correlation = dot / math.sqrt(nearNormSq * farNormSq);
      if (correlation > bestCorrelation) {
        bestCorrelation = correlation;
        bestLag = lag;
      }
    }
    if (bestCorrelation <= -2.0) {
      return null; // Far channel had no variance at any candidate lag.
    }
    return AecDelayEstimate(
      lagMs: bestLag * binMs,
      confidence: bestCorrelation.clamp(0.0, 1.0),
    );
  }

  /// Like [estimate], but smoothed across a short recency ring.
  ///
  /// A single raw measurement can latch onto a transient cross-talk peak on a
  /// noisy or high-latency path. The recency-weighted median rejects that
  /// jitter while still tracking a genuinely drifting delay. The returned
  /// confidence is the latest raw measurement's, so a caller's confidence gate
  /// behaves exactly as it would against [estimate].
  AecDelayEstimate? estimateSmoothed() {
    final AecDelayEstimate? raw = estimate();
    if (raw == null) {
      return null;
    }
    _recent.add(raw);
    if (_recent.length > _recentCap) {
      _recent.removeRange(0, _recent.length - _recentCap);
    }
    return AecDelayEstimate(
      lagMs: recencyWeightedMedianLagMs(_recent),
      confidence: raw.confidence,
    );
  }

  /// Whether recent estimates cluster tightly: at least three of the last five
  /// sit within ±80 ms of their centre.
  ///
  /// This is the second lock tier. A run of mutually agreeing but individually
  /// modest measurements is trustworthy even when no single one clears the hard
  /// confidence gate, which a jittery channel may never produce.
  bool get hasRepeatedSupport {
    if (_recent.length < 3) {
      return false;
    }
    final List<AecDelayEstimate> recentFive = _recent.length <= 5
        ? _recent
        : _recent.sublist(_recent.length - 5);
    final int centre = recencyWeightedMedianLagMs(recentFive);
    final int nearby = recentFive
        .where(
          (AecDelayEstimate e) =>
              (e.lagMs - centre).abs() <= _supportToleranceMs,
        )
        .length;
    return nearby >= 3;
  }

  /// Whether [estimate] clears either lock tier: a single measurement at or
  /// above [minConfidence], or [hasRepeatedSupport].
  bool hasLock(
    AecDelayEstimate? estimate, {
    double minConfidence = defaultLockConfidence,
  }) {
    if (estimate == null) {
      return false;
    }
    return estimate.confidence >= minConfidence || hasRepeatedSupport;
  }

  /// Number of raw measurements currently held in the smoothing ring.
  int get recentEstimateCount => _recent.length;

  /// Drops all envelope history and smoothing state.
  ///
  /// Call when a capture restarts or a device changes: the previously measured
  /// offset describes hardware that is no longer in the path.
  void reset() {
    _far.clear();
    _near.clear();
    _recent.clear();
    _latestBin = -1;
    _firstBin = -1;
  }

  /// Recency-weighted median lag over [estimates], where each estimate's weight
  /// is its one-based position so newer measurements count for more and a lone
  /// outlier cannot swing the result. Pure; exposed for tests.
  static int recencyWeightedMedianLagMs(List<AecDelayEstimate> estimates) {
    if (estimates.isEmpty) {
      return 0;
    }
    final List<({int lagMs, double weight})> weighted =
        <({int lagMs, double weight})>[
          for (var index = 0; index < estimates.length; index += 1)
            (lagMs: estimates[index].lagMs, weight: (index + 1).toDouble()),
        ]..sort(
          (({int lagMs, double weight}) a, ({int lagMs, double weight}) b) =>
              a.lagMs.compareTo(b.lagMs),
        );
    final double total = weighted.fold<double>(
      0,
      (double sum, ({int lagMs, double weight}) e) => sum + e.weight,
    );
    final double mid = total / 2.0;
    var cumulative = 0.0;
    for (final ({int lagMs, double weight}) entry in weighted) {
      cumulative += entry.weight;
      if (cumulative > mid) {
        return entry.lagMs;
      }
    }
    return weighted.last.lagMs;
  }
}
