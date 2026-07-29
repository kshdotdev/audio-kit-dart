// Adapted from Control Center's `meeting_waveform.dart`.
// Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.

import 'dart:typed_data';

/// Mixes complete mono tracks down to one, summing sample-for-sample and
/// hard-clipping to `[-1, 1]`.
///
/// Output length is the longest input; shorter tracks contribute silence past
/// their end. This is the offline counterpart to the streaming mixer: it folds
/// finished recordings of differing lengths — a session's microphone and system
/// tracks, say — into one playable stream, whereas the streaming mixer aligns
/// live tracks onto equal-length timeline blocks and cannot express a ragged
/// tail. Empty tracks are skipped, and an empty result means there was nothing
/// to mix.
///
/// A single present track is returned as-is rather than copied, so treat the
/// result as read-only unless you know you passed more than one track.
Float32List mixTracksToMono(List<Float32List> tracks) {
  final List<Float32List> present = tracks
      .where((Float32List track) => track.isNotEmpty)
      .toList(growable: false);
  if (present.isEmpty) {
    return Float32List(0);
  }
  if (present.length == 1) {
    return present.first;
  }
  var length = 0;
  for (final Float32List track in present) {
    if (track.length > length) {
      length = track.length;
    }
  }
  final Float32List output = Float32List(length);
  for (final Float32List track in present) {
    final int count = track.length;
    for (var index = 0; index < count; index += 1) {
      output[index] = (output[index] + track[index]).clamp(-1.0, 1.0);
    }
  }
  return output;
}

/// Reduces [samples] to [bucketCount] peak-amplitude buckets in `[0, 1]`,
/// suitable for drawing a waveform.
///
/// Each bucket holds the maximum absolute amplitude over its slice, and the set
/// is then normalized so the loudest bucket is `1.0` — a uniformly quiet
/// recording still renders visibly instead of as a flat line. Returns an empty
/// list for empty input or a non-positive [bucketCount].
List<double> peakBuckets(Float32List samples, int bucketCount) {
  if (samples.isEmpty || bucketCount <= 0) {
    return const <double>[];
  }
  final int count = samples.length;
  final List<double> buckets = List<double>.filled(bucketCount, 0);
  var maxPeak = 0.0;
  for (var bucket = 0; bucket < bucketCount; bucket += 1) {
    final int start = (bucket * count) ~/ bucketCount;
    var end = ((bucket + 1) * count) ~/ bucketCount;
    if (end <= start) {
      end = start + 1; // Guarantee at least one sample per bucket.
    }
    var peak = 0.0;
    for (var index = start; index < end && index < count; index += 1) {
      final double amplitude = samples[index].abs();
      if (amplitude > peak) {
        peak = amplitude;
      }
    }
    buckets[bucket] = peak;
    if (peak > maxPeak) {
      maxPeak = peak;
    }
  }
  if (maxPeak > 0) {
    for (var bucket = 0; bucket < bucketCount; bucket += 1) {
      buckets[bucket] = buckets[bucket] / maxPeak;
    }
  }
  return buckets;
}
