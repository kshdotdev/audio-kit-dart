import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'synchronizer.dart';

/// Output normalization used by [AudioMixer].
enum AudioMixMode {
  /// Sum weighted tracks and clamp each sample to the float PCM range.
  sumClipped,

  /// Divide the weighted sum by the total absolute gain, then clamp.
  normalized,
}

/// Explicit mixer for one [SynchronizedAudioBlock].
final class AudioMixer {
  AudioMixer({
    this.mode = AudioMixMode.sumClipped,
    Map<String, double> gains = const <String, double>{},
    this.sourceId = 'mixer',
    this.trackId = 'mix',
  }) : gains = Map<String, double>.unmodifiable(gains) {
    if (sourceId.trim().isEmpty || trackId.trim().isEmpty) {
      throw ArgumentError('Mixer source and track IDs must not be empty.');
    }
    if (gains.values.any((double gain) => !gain.isFinite)) {
      throw ArgumentError.value(gains, 'gains', 'Gains must be finite.');
    }
  }

  /// Mixing behavior.
  final AudioMixMode mode;

  /// Per-track linear gains. Unspecified tracks use 1.
  final Map<String, double> gains;

  /// Source ID assigned to mixed frames.
  final String sourceId;

  /// Track ID assigned to mixed frames.
  final String trackId;

  /// Mixes aligned tracks into one owned float32 frame.
  AudioFrame mix(SynchronizedAudioBlock block) {
    if (block.frames.isEmpty) {
      throw ArgumentError.value(block, 'block', 'Block has no tracks.');
    }
    final int sampleCount = block.frameCount * block.format.channels;
    final Float32List output = Float32List(sampleCount);
    var totalAbsoluteGain = 0.0;
    AudioDiscontinuity? firstDiscontinuity;
    for (final MapEntry<String, AudioFrame> entry in block.frames.entries) {
      final AudioFrame frame = entry.value;
      if (frame.format != block.format || frame.samples.length != sampleCount) {
        throw ArgumentError.value(
          frame,
          'block',
          'Every synchronized frame must share the block format and length.',
        );
      }
      final double gain = gains[entry.key] ?? 1;
      totalAbsoluteGain += gain.abs();
      firstDiscontinuity ??= frame.discontinuity;
      for (var sample = 0; sample < sampleCount; sample += 1) {
        output[sample] += frame.samples[sample] * gain;
      }
    }
    final double divisor = switch (mode) {
      AudioMixMode.sumClipped => 1,
      AudioMixMode.normalized => totalAbsoluteGain == 0 ? 1 : totalAbsoluteGain,
    };
    for (var sample = 0; sample < sampleCount; sample += 1) {
      output[sample] = (output[sample] / divisor).clamp(-1.0, 1.0);
    }
    final AudioFrame first = block.frames.values.first;
    return AudioFrame.owned(
      format: block.format,
      samples: output,
      sourceId: sourceId,
      trackId: trackId,
      clockId: first.clockId,
      sequence: block.sequence,
      sampleOffset: first.sampleOffset,
      timestamp: block.timestamp,
      discontinuity: firstDiscontinuity == null
          ? null
          : AudioDiscontinuity(
              reason: firstDiscontinuity.reason,
              previousSequence: firstDiscontinuity.previousSequence,
              description:
                  'One or more mixed tracks contained a discontinuity already '
                  'materialized in the mixed PCM timeline.',
            ),
    );
  }
}
