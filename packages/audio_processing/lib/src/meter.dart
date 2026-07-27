import 'dart:math' as math;

import 'package:audio_core/audio_core.dart';

import 'processor.dart';

/// Immutable level measurement for one audio frame.
final class AudioMeterReading {
  /// Creates a meter reading.
  AudioMeterReading({
    required this.stream,
    required this.sequence,
    required this.timestamp,
    required this.rms,
    required this.peak,
    required this.decibelsFullScale,
    required this.smoothedRms,
    required this.smoothedPeak,
    required List<double> rmsByChannel,
    required List<double> peakByChannel,
  }) : rmsByChannel = List<double>.unmodifiable(rmsByChannel),
       peakByChannel = List<double>.unmodifiable(peakByChannel);

  /// Stream whose levels were measured.
  final AudioStreamKey stream;

  /// Source frame sequence.
  final int sequence;

  /// Source frame monotonic timestamp.
  final Duration timestamp;

  /// Aggregate root-mean-square amplitude.
  final double rms;

  /// Aggregate absolute peak amplitude.
  final double peak;

  /// Aggregate RMS in dBFS, clamped to the meter floor.
  final double decibelsFullScale;

  /// Attack/release-smoothed aggregate RMS.
  final double smoothedRms;

  /// Attack/release-smoothed aggregate peak.
  final double smoothedPeak;

  /// Root-mean-square amplitude for each channel.
  final List<double> rmsByChannel;

  /// Absolute peak amplitude for each channel.
  final List<double> peakByChannel;
}

/// Per-track RMS/peak meter with time-based attack and release smoothing.
final class AudioMeter {
  /// Creates a meter.
  AudioMeter({
    this.attack = const Duration(milliseconds: 10),
    this.release = const Duration(milliseconds: 300),
    this.decibelFloor = -120,
  }) {
    if (attack <= Duration.zero) {
      throw ArgumentError.value(attack, 'attack', 'Must be positive.');
    }
    if (release <= Duration.zero) {
      throw ArgumentError.value(release, 'release', 'Must be positive.');
    }
    if (!decibelFloor.isFinite || decibelFloor >= 0) {
      throw ArgumentError.value(
        decibelFloor,
        'decibelFloor',
        'Must be a finite negative number.',
      );
    }
  }

  /// Time constant used while levels rise.
  final Duration attack;

  /// Time constant used while levels fall.
  final Duration release;

  /// Minimum reported dBFS value.
  final double decibelFloor;

  final Map<AudioStreamKey, _MeterState> _states =
      <AudioStreamKey, _MeterState>{};

  /// Measures [frame] and updates only its stream's smoothing state.
  AudioMeterReading process(AudioFrame frame) {
    final key = AudioStreamKey.fromFrame(frame);
    if (frame.discontinuity != null) {
      _states.remove(key);
    }

    final channels = frame.format.channels;
    final sumSquares = List<double>.filled(channels, 0);
    final peaks = List<double>.filled(channels, 0);
    var aggregateSquares = 0.0;
    var aggregatePeak = 0.0;
    for (var index = 0; index < frame.samples.length; index += 1) {
      final value = frame.samples[index].toDouble();
      final magnitude = value.abs();
      final channel = index % channels;
      sumSquares[channel] += value * value;
      aggregateSquares += value * value;
      if (magnitude > peaks[channel]) {
        peaks[channel] = magnitude;
      }
      if (magnitude > aggregatePeak) {
        aggregatePeak = magnitude;
      }
    }

    final rmsByChannel = sumSquares
        .map((sum) => math.sqrt(sum / frame.frameCount))
        .toList(growable: false);
    final rms = math.sqrt(aggregateSquares / frame.samples.length);
    final previous = _states[key];
    final smoothedRms = _smooth(previous?.rms, rms, frame.duration);
    final smoothedPeak = _smooth(previous?.peak, aggregatePeak, frame.duration);
    _states[key] = _MeterState(rms: smoothedRms, peak: smoothedPeak);

    final decibels = rms == 0
        ? decibelFloor
        : math.max(decibelFloor, 20 * (math.log(rms) / math.ln10));
    return AudioMeterReading(
      stream: key,
      sequence: frame.sequence,
      timestamp: frame.timestamp,
      rms: rms,
      peak: aggregatePeak,
      decibelsFullScale: decibels,
      smoothedRms: smoothedRms,
      smoothedPeak: smoothedPeak,
      rmsByChannel: rmsByChannel,
      peakByChannel: peaks,
    );
  }

  /// Discards smoothing state for [stream], or every stream when omitted.
  void reset({AudioStreamKey? stream}) {
    if (stream == null) {
      _states.clear();
    } else {
      _states.remove(stream);
    }
  }

  double _smooth(double? previous, double next, Duration frameDuration) {
    if (previous == null) {
      return next;
    }
    final timeConstant = next > previous ? attack : release;
    final elapsedMicros = math.max(frameDuration.inMicroseconds, 1);
    final alpha = math.exp(
      -elapsedMicros / timeConstant.inMicroseconds.toDouble(),
    );
    return (alpha * previous) + ((1 - alpha) * next);
  }
}

final class _MeterState {
  const _MeterState({required this.rms, required this.peak});

  final double rms;
  final double peak;
}
