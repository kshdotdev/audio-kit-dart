import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'processor.dart';

/// Repackages arbitrary frame sizes into deterministic fixed-size chunks.
final class AudioRechunker implements AudioFrameProcessor {
  /// Creates a rechunker that emits [targetFrameCount] sample frames at a time.
  AudioRechunker({required this.targetFrameCount}) {
    if (targetFrameCount <= 0) {
      throw ArgumentError.value(
        targetFrameCount,
        'targetFrameCount',
        'Must be positive.',
      );
    }
  }

  /// Desired interleaved sample-frame count for every non-final chunk.
  final int targetFrameCount;

  final Map<AudioStreamKey, _RechunkState> _states =
      <AudioStreamKey, _RechunkState>{};

  @override
  List<AudioFrame> process(AudioFrame frame) {
    final key = AudioStreamKey.fromFrame(frame);
    var state = _states[key];
    final output = <AudioFrame>[];
    state ??= _RechunkState.fromFrame(frame);
    _states[key] = state;

    final formatChanged = state.format != frame.format;
    final expectedOffset = state.nextInputOffset;
    final continuityChanged =
        expectedOffset != null && expectedOffset != frame.sampleOffset;
    if (formatChanged || frame.discontinuity != null || continuityChanged) {
      final partial = state.flushPartial();
      if (partial != null) {
        output.add(partial);
      }
      state.restart(
        frame,
        implicitDiscontinuity: continuityChanged && frame.discontinuity == null,
      );
    }

    state.append(frame);
    final samplesPerChunk = targetFrameCount * frame.format.channels;
    while (state.buffer.length >= samplesPerChunk) {
      output.add(state.take(samplesPerChunk));
    }
    return output;
  }

  @override
  List<AudioFrame> flush({AudioStreamKey? stream}) {
    final keys = stream == null
        ? List<AudioStreamKey>.of(_states.keys)
        : <AudioStreamKey>[stream];
    final output = <AudioFrame>[];
    for (final key in keys) {
      final state = _states.remove(key);
      final partial = state?.flushPartial();
      if (partial != null) {
        output.add(partial);
      }
    }
    return output;
  }

  @override
  void reset({AudioStreamKey? stream}) {
    if (stream == null) {
      _states.clear();
    } else {
      _states.remove(stream);
    }
  }
}

final class _RechunkState {
  _RechunkState.fromFrame(AudioFrame frame)
    : format = frame.format,
      sourceId = frame.sourceId,
      trackId = frame.trackId,
      clockId = frame.clockId,
      outputSequence = frame.sequence;

  AudioFormat format;
  String sourceId;
  String trackId;
  String clockId;
  int outputSequence;
  final List<double> buffer = <double>[];
  int? bufferSampleOffset;
  int? timelineAnchorOffset;
  Duration? timelineAnchorTimestamp;
  int? nextInputOffset;
  AudioDiscontinuity? pendingDiscontinuity;

  void restart(AudioFrame frame, {required bool implicitDiscontinuity}) {
    format = frame.format;
    sourceId = frame.sourceId;
    trackId = frame.trackId;
    clockId = frame.clockId;
    bufferSampleOffset = null;
    timelineAnchorOffset = frame.sampleOffset;
    timelineAnchorTimestamp = frame.timestamp;
    nextInputOffset = null;
    pendingDiscontinuity =
        frame.discontinuity ??
        (implicitDiscontinuity
            ? AudioDiscontinuity(
                reason: AudioDiscontinuityReason.unknown,
                description: 'Non-contiguous sample offsets were rechunked.',
              )
            : null);
  }

  void append(AudioFrame frame) {
    bufferSampleOffset ??= frame.sampleOffset;
    timelineAnchorOffset ??= frame.sampleOffset;
    timelineAnchorTimestamp ??= frame.timestamp;
    pendingDiscontinuity ??= frame.discontinuity;
    buffer.addAll(frame.samples);
    nextInputOffset = frame.endSampleOffset;
  }

  AudioFrame take(int sampleCount) {
    final samples = Float32List.fromList(buffer.sublist(0, sampleCount));
    buffer.removeRange(0, sampleCount);
    final sampleOffset = bufferSampleOffset;
    final anchorOffset = timelineAnchorOffset;
    final anchorTimestamp = timelineAnchorTimestamp;
    if (sampleOffset == null ||
        anchorOffset == null ||
        anchorTimestamp == null) {
      throw StateError('Rechunk buffer metadata is missing.');
    }
    final timestamp =
        anchorTimestamp + format.durationForFrames(sampleOffset - anchorOffset);
    final output = AudioFrame.owned(
      format: format,
      samples: samples,
      sourceId: sourceId,
      trackId: trackId,
      clockId: clockId,
      sequence: outputSequence,
      sampleOffset: sampleOffset,
      timestamp: timestamp,
      discontinuity: pendingDiscontinuity,
    );
    outputSequence += 1;
    bufferSampleOffset = sampleOffset + output.frameCount;
    pendingDiscontinuity = null;
    return output;
  }

  AudioFrame? flushPartial() {
    if (buffer.isEmpty) {
      return null;
    }
    return take(buffer.length);
  }
}
