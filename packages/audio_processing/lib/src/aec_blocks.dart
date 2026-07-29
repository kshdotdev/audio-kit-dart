// The block-accumulation strategy is adapted from Control Center's
// `aec_mic_filter.dart` (`_BlockAccumulator`).
// Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.
//
// Adaptation notes: the original accumulates PCM16 bytes because its capture
// backends emit PCM16. This port accumulates float32 sample frames — Audio
// Kit's canonical form — and performs the int16 conversion at the block
// boundary, which is the only edge where an echo canceller requires it.

import 'dart:typed_data';

/// Sample frames in one 10 ms block at 16 kHz.
///
/// WebRTC's echo canceller processes exactly 10 ms of mono audio per call, so
/// every submission must be chopped to this size regardless of the frame sizes
/// a capture backend happens to deliver.
const int kAecBlockFrames = 160;

/// Converts float32 PCM in `[-1, 1]` to signed 16-bit PCM.
///
/// Values outside the nominal range are clamped rather than allowed to wrap,
/// which would turn a loud passage into broadband noise.
Int16List floatToPcm16(Float32List samples) {
  final Int16List output = Int16List(samples.length);
  for (var index = 0; index < samples.length; index += 1) {
    output[index] = _sampleToPcm16(samples[index]);
  }
  return output;
}

/// Converts signed 16-bit PCM back to float32 in `[-1, 1]`.
///
/// Uses the same 32767 scale as [floatToPcm16], so a round trip is accurate to
/// within one quantization step.
Float32List pcm16ToFloat(Int16List samples) {
  final Float32List output = Float32List(samples.length);
  for (var index = 0; index < samples.length; index += 1) {
    output[index] = (samples[index] / 32767.0).clamp(-1.0, 1.0);
  }
  return output;
}

int _sampleToPcm16(double sample) {
  if (sample.isNaN) {
    return 0;
  }
  final double scaled = sample * 32767.0;
  if (scaled >= 32767.0) {
    return 32767;
  }
  if (scaled <= -32768.0) {
    return -32768;
  }
  return scaled.round();
}

/// Chops a float32 sample stream into fixed-size int16 blocks, carrying the
/// remainder across calls.
///
/// Capture backends deliver whatever frame size their platform prefers, while
/// an echo canceller demands exact 10 ms blocks. This sits between them: feed
/// arbitrary chunks to [add] and receive exactly-sized blocks, with leftover
/// samples retained for the next call so no audio is dropped or duplicated at
/// chunk seams.
///
/// State is per-instance; use one accumulator per stream and pair it with an
/// explicit [reset] when the stream restarts.
final class AecBlockAccumulator {
  /// Creates an accumulator emitting [blockFrames]-sample blocks.
  AecBlockAccumulator({this.blockFrames = kAecBlockFrames})
    : _carry = Float32List(blockFrames) {
    if (blockFrames <= 0) {
      throw ArgumentError.value(
        blockFrames,
        'blockFrames',
        'Must be positive.',
      );
    }
  }

  /// Sample frames per emitted block.
  final int blockFrames;

  final Float32List _carry;
  int _carryLength = 0;

  /// Samples buffered but not yet emitted as a complete block.
  int get pendingFrameCount => _carryLength;

  /// Appends [samples] and invokes [onBlock] for each complete block.
  ///
  /// Blocks are freshly allocated and safe to retain. Any trailing partial
  /// block is carried into the next call.
  void add(Float32List samples, void Function(Int16List block) onBlock) {
    var offset = 0;
    final int count = samples.length;

    // Top up an in-progress block first.
    if (_carryLength > 0) {
      final int needed = blockFrames - _carryLength;
      final int available = count < needed ? count : needed;
      for (var index = 0; index < available; index += 1) {
        _carry[_carryLength + index] = samples[index];
      }
      _carryLength += available;
      offset = available;
      if (_carryLength < blockFrames) {
        return;
      }
      onBlock(_toPcm16(_carry, 0, blockFrames));
      _carryLength = 0;
    }

    // Emit whole blocks straight from the input.
    while (count - offset >= blockFrames) {
      onBlock(_toPcm16(samples, offset, blockFrames));
      offset += blockFrames;
    }

    // Retain the remainder.
    final int remainder = count - offset;
    for (var index = 0; index < remainder; index += 1) {
      _carry[index] = samples[offset + index];
    }
    _carryLength = remainder;
  }

  /// Emits the buffered remainder as one block padded with silence, or `null`
  /// when nothing is pending.
  ///
  /// Call at end of stream. Mid-stream padding would insert a silent gap into
  /// the canceller's timeline and desynchronize the reference from the capture.
  Int16List? drain() {
    if (_carryLength == 0) {
      return null;
    }
    final Int16List block = Int16List(blockFrames);
    for (var index = 0; index < _carryLength; index += 1) {
      block[index] = _sampleToPcm16(_carry[index]);
    }
    _carryLength = 0;
    return block;
  }

  /// Discards buffered samples without emitting them.
  void reset() => _carryLength = 0;

  static Int16List _toPcm16(Float32List source, int offset, int length) {
    final Int16List block = Int16List(length);
    for (var index = 0; index < length; index += 1) {
      block[index] = _sampleToPcm16(source[offset + index]);
    }
    return block;
  }
}
