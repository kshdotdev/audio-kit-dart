import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'processor.dart';

/// Streaming linear-interpolation resampler with isolated state per track.
///
/// The implementation maintains one source-sample look-behind, so output is
/// invariant to input chunk boundaries. Call [flush] at end of stream.
final class AudioResampler implements AudioFrameProcessor {
  /// Creates a resampler targeting [outputSampleRate].
  AudioResampler({required this.outputSampleRate}) {
    if (outputSampleRate <= 0) {
      throw ArgumentError.value(
        outputSampleRate,
        'outputSampleRate',
        'Must be positive.',
      );
    }
  }

  /// Target sample frames per second.
  final int outputSampleRate;

  final Map<AudioStreamKey, _ResampleState> _states =
      <AudioStreamKey, _ResampleState>{};

  @override
  List<AudioFrame> process(AudioFrame frame) {
    final key = AudioStreamKey.fromFrame(frame);
    if (frame.format.sampleRate == outputSampleRate) {
      _states.remove(key);
      return <AudioFrame>[frame.copyWith()];
    }

    var state = _states[key];
    final formatChanged = state != null && state.inputFormat != frame.format;
    final offsetChanged =
        state != null && state.expectedInputOffset != frame.sampleOffset;
    final requiresReset =
        state == null ||
        formatChanged ||
        frame.discontinuity != null ||
        offsetChanged;
    if (requiresReset) {
      final int inputOffsetGap = state == null
          ? 0
          : frame.sampleOffset - state.expectedInputOffset;
      final discontinuity =
          _scaleDiscontinuity(
            frame.discontinuity,
            inputSampleRate: frame.format.sampleRate,
            outputSampleRate: outputSampleRate,
          ) ??
          (formatChanged
              ? AudioDiscontinuity(
                  reason: AudioDiscontinuityReason.formatChange,
                  description: 'The resampler input format changed.',
                )
              : offsetChanged
              ? AudioDiscontinuity(
                  reason: AudioDiscontinuityReason.unknown,
                  droppedSampleFrameCount: _scaleSampleFrameCount(
                    inputOffsetGap > 0 ? inputOffsetGap : 0,
                    inputSampleRate: frame.format.sampleRate,
                    outputSampleRate: outputSampleRate,
                  ),
                  description:
                      'Non-contiguous sample offsets reset the resampler.',
                )
              : null);
      state = _ResampleState.fromFrame(
        frame,
        outputSampleRate,
        discontinuity: discontinuity,
      );
      _states[key] = state;
    }

    final channels = frame.format.channels;
    final inputFrames = frame.frameCount;
    final ratio = frame.format.sampleRate / outputSampleRate;
    final output = <double>[];

    if (state.previous == null) {
      var position = 0.0;
      final limit = inputFrames - 1;
      while (position < limit) {
        _appendInterpolated(
          output: output,
          position: position,
          channels: channels,
          current: frame.samples,
          previous: null,
        );
        position += ratio;
      }
      state.nextPosition = position - limit;
    } else {
      var position = state.nextPosition;
      final limit = inputFrames;
      while (position < limit) {
        _appendInterpolated(
          output: output,
          position: position,
          channels: channels,
          current: frame.samples,
          previous: state.previous,
        );
        position += ratio;
      }
      state.nextPosition = position - limit;
    }

    state
      ..previous = Float32List.fromList(
        frame.samples.sublist(
          (inputFrames - 1) * channels,
          inputFrames * channels,
        ),
      )
      ..expectedInputOffset = frame.endSampleOffset
      ..lastInput = frame
      ..pendingDiscontinuity ??= _scaleDiscontinuity(
        frame.discontinuity,
        inputSampleRate: frame.format.sampleRate,
        outputSampleRate: outputSampleRate,
      );

    if (output.isEmpty) {
      return const <AudioFrame>[];
    }
    return <AudioFrame>[state.createOutput(Float32List.fromList(output))];
  }

  @override
  List<AudioFrame> flush({AudioStreamKey? stream}) {
    final entries = stream == null
        ? List<MapEntry<AudioStreamKey, _ResampleState>>.of(_states.entries)
        : <MapEntry<AudioStreamKey, _ResampleState>>[
            if (_states[stream] case final state?)
              MapEntry<AudioStreamKey, _ResampleState>(stream, state),
          ];
    final output = <AudioFrame>[];
    for (final entry in entries) {
      final state = entry.value;
      final previous = state.previous;
      if (previous != null && state.nextPosition.abs() < 1e-9) {
        output.add(state.createOutput(Float32List.fromList(previous)));
      }
      _states.remove(entry.key);
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

AudioDiscontinuity? _scaleDiscontinuity(
  AudioDiscontinuity? discontinuity, {
  required int inputSampleRate,
  required int outputSampleRate,
}) {
  if (discontinuity == null) {
    return null;
  }
  return AudioDiscontinuity(
    reason: discontinuity.reason,
    droppedFrameCount: discontinuity.droppedFrameCount,
    droppedSampleFrameCount: _scaleSampleFrameCount(
      discontinuity.droppedSampleFrameCount,
      inputSampleRate: inputSampleRate,
      outputSampleRate: outputSampleRate,
    ),
    previousSequence: discontinuity.previousSequence,
    description: discontinuity.description,
  );
}

int _scaleSampleFrameCount(
  int frameCount, {
  required int inputSampleRate,
  required int outputSampleRate,
}) =>
    ((frameCount * outputSampleRate) + (inputSampleRate ~/ 2)) ~/
    inputSampleRate;

void _appendInterpolated({
  required List<double> output,
  required double position,
  required int channels,
  required Float32List current,
  required Float32List? previous,
}) {
  final lower = position.floor();
  final fraction = position - lower;
  for (var channel = 0; channel < channels; channel += 1) {
    final lowerValue = previous == null
        ? current[lower * channels + channel]
        : lower == 0
        ? previous[channel]
        : current[(lower - 1) * channels + channel];
    final upperValue = previous == null
        ? current[(lower + 1) * channels + channel]
        : current[lower * channels + channel];
    output.add(lowerValue + ((upperValue - lowerValue) * fraction));
  }
}

final class _ResampleState {
  _ResampleState.fromFrame(
    AudioFrame frame,
    this.outputSampleRate, {
    required AudioDiscontinuity? discontinuity,
  }) : inputFormat = frame.format,
       expectedInputOffset = frame.sampleOffset,
       outputSampleOffset =
           (frame.sampleOffset * outputSampleRate) ~/ frame.format.sampleRate,
       outputSequence = frame.sequence,
       anchorOutputSampleOffset =
           (frame.sampleOffset * outputSampleRate) ~/ frame.format.sampleRate,
       anchorTimestamp = frame.timestamp,
       pendingDiscontinuity = discontinuity;

  final AudioFormat inputFormat;
  final int outputSampleRate;
  int expectedInputOffset;
  int outputSampleOffset;
  int outputSequence;
  final int anchorOutputSampleOffset;
  final Duration anchorTimestamp;
  double nextPosition = 0;
  Float32List? previous;
  AudioFrame? lastInput;
  AudioDiscontinuity? pendingDiscontinuity;

  AudioFrame createOutput(Float32List samples) {
    final input = lastInput;
    if (input == null) {
      throw StateError(
        'Cannot create resampled output without input metadata.',
      );
    }
    final outputFormat = AudioFormat(
      sampleRate: outputSampleRate,
      channels: inputFormat.channels,
    );
    final output = AudioFrame.owned(
      format: outputFormat,
      samples: samples,
      sourceId: input.sourceId,
      trackId: input.trackId,
      clockId: input.clockId,
      sequence: outputSequence,
      sampleOffset: outputSampleOffset,
      timestamp:
          anchorTimestamp +
          outputFormat.durationForFrames(
            outputSampleOffset - anchorOutputSampleOffset,
          ),
      discontinuity: pendingDiscontinuity,
    );
    pendingDiscontinuity = null;
    outputSequence += 1;
    outputSampleOffset += output.frameCount;
    return output;
  }
}
