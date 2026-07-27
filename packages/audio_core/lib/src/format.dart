/// PCM sample representation used by an audio session.
enum AudioSampleFormat {
  /// Native-endian, normalized IEEE 754 single-precision samples.
  float32(bytesPerSample: 4);

  const AudioSampleFormat({required this.bytesPerSample});

  /// Number of bytes occupied by one sample.
  final int bytesPerSample;
}

/// Fixed PCM layout for one audio session.
final class AudioFormat {
  /// Creates a validated interleaved PCM format.
  AudioFormat({
    required this.sampleRate,
    required this.channels,
    this.sampleFormat = AudioSampleFormat.float32,
  }) {
    if (sampleRate <= 0) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'Must be positive.');
    }
    if (channels <= 0) {
      throw ArgumentError.value(channels, 'channels', 'Must be positive.');
    }
  }

  /// Sample frames per second.
  final int sampleRate;

  /// Number of interleaved channels in each sample frame.
  final int channels;

  /// Representation of each channel sample.
  final AudioSampleFormat sampleFormat;

  /// Bytes occupied by one interleaved sample frame.
  int get bytesPerFrame => channels * sampleFormat.bytesPerSample;

  /// Duration represented by [frameCount].
  Duration durationForFrames(int frameCount) {
    if (frameCount < 0) {
      throw ArgumentError.value(
        frameCount,
        'frameCount',
        'Must not be negative.',
      );
    }
    return Duration(
      microseconds: (frameCount * Duration.microsecondsPerSecond) ~/ sampleRate,
    );
  }

  /// Sample-frame count represented by [duration], rounded down.
  int framesForDuration(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'Must not be negative.');
    }
    return (duration.inMicroseconds * sampleRate) ~/
        Duration.microsecondsPerSecond;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioFormat &&
          sampleRate == other.sampleRate &&
          channels == other.channels &&
          sampleFormat == other.sampleFormat;

  @override
  int get hashCode => Object.hash(sampleRate, channels, sampleFormat);

  @override
  String toString() =>
      'AudioFormat(sampleRate: $sampleRate, channels: $channels, '
      'sampleFormat: ${sampleFormat.name})';
}
