import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'processor.dart';

/// Mono downmix weighting strategy.
enum AudioDownmixStrategy {
  /// Arithmetic mean of every input channel, preserving headroom.
  average,

  /// Copy only the first input channel.
  firstChannel,
}

/// Stateful-per-track interleaved PCM to mono downmixer.
final class AudioDownmixer implements AudioFrameProcessor {
  /// Creates a mono downmixer.
  AudioDownmixer({this.strategy = AudioDownmixStrategy.average});

  /// Channel weighting strategy.
  final AudioDownmixStrategy strategy;

  final Map<AudioStreamKey, AudioFormat> _formats =
      <AudioStreamKey, AudioFormat>{};

  @override
  List<AudioFrame> process(AudioFrame frame) {
    final key = AudioStreamKey.fromFrame(frame);
    final previousFormat = _formats[key];
    if (previousFormat != null && previousFormat != frame.format) {
      if (frame.discontinuity?.reason !=
          AudioDiscontinuityReason.formatChange) {
        throw StateError(
          'Format changed for $key without a formatChange discontinuity.',
        );
      }
    }
    _formats[key] = frame.format;

    if (frame.format.channels == 1) {
      return <AudioFrame>[frame.copyWith()];
    }

    final output = Float32List(frame.frameCount);
    final channels = frame.format.channels;
    for (
      var sampleFrame = 0;
      sampleFrame < frame.frameCount;
      sampleFrame += 1
    ) {
      final base = sampleFrame * channels;
      switch (strategy) {
        case AudioDownmixStrategy.average:
          var sum = 0.0;
          for (var channel = 0; channel < channels; channel += 1) {
            sum += frame.samples[base + channel];
          }
          output[sampleFrame] = sum / channels;
        case AudioDownmixStrategy.firstChannel:
          output[sampleFrame] = frame.samples[base];
      }
    }

    return <AudioFrame>[
      AudioFrame.owned(
        format: AudioFormat(sampleRate: frame.format.sampleRate, channels: 1),
        samples: output,
        sourceId: frame.sourceId,
        trackId: frame.trackId,
        clockId: frame.clockId,
        sequence: frame.sequence,
        sampleOffset: frame.sampleOffset,
        timestamp: frame.timestamp,
        discontinuity: frame.discontinuity,
      ),
    ];
  }

  @override
  List<AudioFrame> flush({AudioStreamKey? stream}) => const <AudioFrame>[];

  @override
  void reset({AudioStreamKey? stream}) {
    if (stream == null) {
      _formats.clear();
    } else {
      _formats.remove(stream);
    }
  }
}
