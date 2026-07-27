import 'dart:typed_data';

import 'format.dart';

/// Why continuity was broken immediately before an [AudioFrame].
enum AudioDiscontinuityReason {
  /// One or more frames were discarded by a bounded route.
  droppedFrames,

  /// Capture or synthesis restarted.
  sourceRestart,

  /// The source clock was reset or replaced.
  clockReset,

  /// The PCM format changed.
  formatChange,

  /// A provider-specific discontinuity without a more precise mapping.
  unknown,
}

/// Structured continuity metadata attached to the first frame after a gap.
final class AudioDiscontinuity {
  /// Creates discontinuity metadata.
  AudioDiscontinuity({
    required this.reason,
    this.droppedFrameCount = 0,
    this.droppedSampleFrameCount = 0,
    this.previousSequence,
    this.description,
  }) {
    if (droppedFrameCount < 0) {
      throw ArgumentError.value(
        droppedFrameCount,
        'droppedFrameCount',
        'Must not be negative.',
      );
    }
    if (droppedSampleFrameCount < 0) {
      throw ArgumentError.value(
        droppedSampleFrameCount,
        'droppedSampleFrameCount',
        'Must not be negative.',
      );
    }
    if (previousSequence != null && previousSequence! < 0) {
      throw ArgumentError.value(
        previousSequence,
        'previousSequence',
        'Must not be negative.',
      );
    }
  }

  /// General reason for the discontinuity.
  final AudioDiscontinuityReason reason;

  /// Number of discarded [AudioFrame] objects, when known.
  final int droppedFrameCount;

  /// Number of discarded interleaved sample frames, when known.
  final int droppedSampleFrameCount;

  /// Sequence immediately before the gap, when known.
  final int? previousSequence;

  /// Safe diagnostic detail.
  final String? description;
}

/// An owned, interleaved float32 PCM buffer and its timeline metadata.
///
/// Instances created with the default constructor copy [samples]. Instances
/// created with [AudioFrame.owned] take exclusive ownership of the supplied
/// list; callers must not mutate that list afterwards. Consumers must treat
/// [samples] as read-only.
final class AudioFrame {
  /// Creates a frame by copying [samples].
  factory AudioFrame({
    required AudioFormat format,
    required Float32List samples,
    required String sourceId,
    required String trackId,
    required String clockId,
    required int sequence,
    required int sampleOffset,
    required Duration timestamp,
    AudioDiscontinuity? discontinuity,
  }) => AudioFrame.owned(
    format: format,
    samples: Float32List.fromList(samples),
    sourceId: sourceId,
    trackId: trackId,
    clockId: clockId,
    sequence: sequence,
    sampleOffset: sampleOffset,
    timestamp: timestamp,
    discontinuity: discontinuity,
  );

  /// Creates a frame by taking exclusive ownership of [samples].
  AudioFrame.owned({
    required this.format,
    required this.samples,
    required this.sourceId,
    required this.trackId,
    required this.clockId,
    required this.sequence,
    required this.sampleOffset,
    required this.timestamp,
    this.discontinuity,
  }) {
    if (format.sampleFormat != AudioSampleFormat.float32) {
      throw ArgumentError.value(
        format.sampleFormat,
        'format',
        'AudioFrame requires float32 PCM.',
      );
    }
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', 'Must not be empty.');
    }
    if (samples.length % format.channels != 0) {
      throw ArgumentError.value(
        samples.length,
        'samples',
        'Length must be divisible by the channel count.',
      );
    }
    _requireIdentifier(sourceId, 'sourceId');
    _requireIdentifier(trackId, 'trackId');
    _requireIdentifier(clockId, 'clockId');
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence', 'Must not be negative.');
    }
    if (sampleOffset < 0) {
      throw ArgumentError.value(
        sampleOffset,
        'sampleOffset',
        'Must not be negative.',
      );
    }
    if (timestamp.isNegative) {
      throw ArgumentError.value(
        timestamp,
        'timestamp',
        'Must not be negative.',
      );
    }
  }

  /// PCM layout shared by every frame in the session.
  final AudioFormat format;

  /// Owned interleaved PCM values. Consumers must not mutate this list.
  final Float32List samples;

  /// Stable capture or synthesis source ID.
  final String sourceId;

  /// Stable logical track ID within [sourceId].
  final String trackId;

  /// Stable monotonic clock domain ID.
  final String clockId;

  /// Monotonically increasing source sequence.
  final int sequence;

  /// Offset of the first sample frame on the source timeline.
  final int sampleOffset;

  /// Monotonic timestamp of the first sample frame.
  final Duration timestamp;

  /// Continuity break immediately before this frame.
  final AudioDiscontinuity? discontinuity;

  /// Number of interleaved sample frames.
  int get frameCount => samples.length ~/ format.channels;

  /// Duration represented by this frame.
  Duration get duration => format.durationForFrames(frameCount);

  /// Exclusive sample-frame offset after this frame.
  int get endSampleOffset => sampleOffset + frameCount;

  /// Creates an independent copy, optionally replacing metadata.
  AudioFrame copyWith({
    AudioFormat? format,
    Float32List? samples,
    String? sourceId,
    String? trackId,
    String? clockId,
    int? sequence,
    int? sampleOffset,
    Duration? timestamp,
    AudioDiscontinuity? discontinuity,
    bool clearDiscontinuity = false,
  }) => AudioFrame(
    format: format ?? this.format,
    samples: samples ?? this.samples,
    sourceId: sourceId ?? this.sourceId,
    trackId: trackId ?? this.trackId,
    clockId: clockId ?? this.clockId,
    sequence: sequence ?? this.sequence,
    sampleOffset: sampleOffset ?? this.sampleOffset,
    timestamp: timestamp ?? this.timestamp,
    discontinuity: clearDiscontinuity
        ? null
        : (discontinuity ?? this.discontinuity),
  );
}

void _requireIdentifier(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
}
