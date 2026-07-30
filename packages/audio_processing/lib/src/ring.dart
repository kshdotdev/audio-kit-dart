import 'dart:math' as math;
import 'dart:typed_data';

/// Fixed-capacity ring of mono samples addressed by an absolute write index.
///
/// The index is the point. A detector that asks a VAD where speech started is
/// handed a position counted from the beginning of the stream, and it needs the
/// audio at that position — but the buffer holding that audio has wrapped
/// several times since. Storing samples under absolute indices makes the two
/// vocabularies the same one: [samples] takes stream positions, not offsets
/// into storage, and the wraparound stays private to this class.
///
/// Requests reaching further back than [capacity] are clipped to what is still
/// buffered rather than wrapped around into unrelated audio. Silently returning
/// samples from the wrong moment would be indistinguishable from success.
final class AudioRing {
  /// Creates a ring holding the most recent [capacity] samples.
  AudioRing({this.capacity = defaultCapacity})
    : _storage = Float32List(capacity) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be positive.');
    }
  }

  /// Ten seconds at 16 kHz.
  ///
  /// Sized for turn detection: an eight-second classifier window plus the
  /// pre-speech margin ahead of it, with room for the pause that triggered the
  /// request to have elapsed before the window is cut.
  static const int defaultCapacity = 160000;

  /// Number of samples retained.
  final int capacity;

  final Float32List _storage;
  int _writeIndex = 0;

  /// Total samples ever written.
  ///
  /// The ring currently holds `[writeIndex - capacity, writeIndex)`, clamped at
  /// zero.
  int get writeIndex => _writeIndex;

  /// Oldest absolute index still buffered.
  int get availableStart => math.max(0, _writeIndex - capacity);

  /// Appends [samples], evicting the oldest audio once full.
  void append(List<double> samples) {
    for (final sample in samples) {
      _storage[_writeIndex % capacity] = sample;
      _writeIndex += 1;
    }
  }

  /// Samples in the absolute range `[from, to)`, clipped to what is buffered.
  ///
  /// Ranges older than [availableStart] are truncated at the head, ranges
  /// beyond [writeIndex] are truncated at the tail, and a range with nothing
  /// left in it returns empty.
  Float32List samples({required int from, required int to}) {
    final low = math.max(from, availableStart);
    final high = math.min(to, _writeIndex);
    if (high <= low) {
      return Float32List(0);
    }
    final output = Float32List(high - low);
    for (var index = low; index < high; index += 1) {
      output[index - low] = _storage[index % capacity];
    }
    return output;
  }

  /// Drops every buffered sample and restarts the absolute index at zero.
  ///
  /// For reusing a ring across independent streams; a discontinuity inside one
  /// stream must not reset the index, because the positions the VAD reports
  /// keep counting.
  void clear() {
    _storage.fillRange(0, _storage.length, 0);
    _writeIndex = 0;
  }
}
