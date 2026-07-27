import 'package:audio_core/audio_core.dart';

/// Stable key used to isolate transform state for simultaneous tracks.
final class AudioStreamKey {
  /// Creates a stream key.
  const AudioStreamKey({
    required this.sourceId,
    required this.trackId,
    required this.clockId,
  });

  /// Creates a key from [frame].
  factory AudioStreamKey.fromFrame(AudioFrame frame) => AudioStreamKey(
    sourceId: frame.sourceId,
    trackId: frame.trackId,
    clockId: frame.clockId,
  );

  /// Source identifier.
  final String sourceId;

  /// Logical track identifier.
  final String trackId;

  /// Monotonic clock-domain identifier.
  final String clockId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioStreamKey &&
          sourceId == other.sourceId &&
          trackId == other.trackId &&
          clockId == other.clockId;

  @override
  int get hashCode => Object.hash(sourceId, trackId, clockId);

  @override
  String toString() => '$sourceId/$trackId@$clockId';
}

/// Synchronous stateful transform that may emit zero or more frames per input.
abstract interface class AudioFrameProcessor {
  /// Processes one frame while preserving independent state per stream key.
  List<AudioFrame> process(AudioFrame frame);

  /// Flushes buffered output for [stream], or every stream when omitted.
  List<AudioFrame> flush({AudioStreamKey? stream});

  /// Discards state for [stream], or every stream when omitted.
  void reset({AudioStreamKey? stream});
}
