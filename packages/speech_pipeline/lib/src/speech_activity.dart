import 'dart:math' as math;
import 'dart:typed_data';

// Derived from Control Center's `speech_activity_detector.dart`
// (MIT © 2026 Samuel Alev). Adapted to operate on normalized float32 samples
// rather than little-endian PCM16 byte buffers. See NOTICE.

/// Decides whether a chunk of audio contains speech.
///
/// The pipeline uses this to gate decodes — windows that never rose above the
/// gate are never sent to a recognizer, because silence makes models emit
/// hallucinated non-speech tokens and burns a decode for nothing.
///
/// Implementations are stateful by contract: one detector belongs to exactly
/// one stream, and [reset] is called before the first chunk.
abstract interface class SpeechActivityDetector {
  /// Whether [samples] (normalized float32, mono) currently contains speech.
  bool isSpeech(Float32List samples);

  /// Resets streaming state. Called once before a stream's first chunk.
  void reset();

  /// Releases any resources held by the detector.
  void dispose();
}

/// Energy-threshold speech gate: speech iff a chunk's RMS amplitude is at or
/// above [threshold].
///
/// The portable fallback used whenever a learned detector (Silero) is not
/// available. [threshold] is expressed on the normalized 0–1 amplitude scale,
/// which is the scale [AudioFrame] samples already use — no conversion is
/// applied, and none is needed.
final class RmsSpeechActivityDetector implements SpeechActivityDetector {
  /// Creates an energy gate.
  ///
  /// The default matches Control Center's production value. That constant is
  /// safe to carry across unchanged because Control Center computes RMS *after*
  /// dividing each PCM16 sample by 32768, so its threshold was always on the
  /// normalized 0–1 scale that float32 frames use natively.
  const RmsSpeechActivityDetector({this.threshold = 0.012});

  /// RMS at or above this (normalized 0–1) counts as speech.
  final double threshold;

  @override
  bool isSpeech(Float32List samples) => rmsOfSamples(samples) >= threshold;

  @override
  void reset() {}

  @override
  void dispose() {}
}

/// A gate that fires only when every wrapped detector agrees.
///
/// Pairs a learned detector with an energy floor: the learned model answers
/// "is this speech?" (it flags quiet residual echo bleed too), the energy floor
/// answers "is it loud enough to be the near party?". Requiring both keeps the
/// learned detector's anti-hallucination benefit without re-decoding residual
/// bleed that an echo canceller attenuated but did not fully remove.
final class AndSpeechActivityDetector implements SpeechActivityDetector {
  /// Creates a gate requiring unanimity across [detectors].
  AndSpeechActivityDetector(Iterable<SpeechActivityDetector> detectors)
    : _detectors = List<SpeechActivityDetector>.unmodifiable(detectors) {
    if (_detectors.isEmpty) {
      throw ArgumentError.value(detectors, 'detectors', 'Must not be empty.');
    }
  }

  final List<SpeechActivityDetector> _detectors;

  @override
  bool isSpeech(Float32List samples) {
    // Every detector sees every chunk: a learned detector is stateful and
    // short-circuiting would corrupt its internal history.
    var speech = true;
    for (final detector in _detectors) {
      if (!detector.isSpeech(samples)) {
        speech = false;
      }
    }
    return speech;
  }

  @override
  void reset() {
    for (final detector in _detectors) {
      detector.reset();
    }
  }

  @override
  void dispose() {
    for (final detector in _detectors) {
      detector.dispose();
    }
  }
}

/// Root-mean-square amplitude of normalized float32 [samples], in 0–1.
///
/// Returns zero for an empty buffer.
double rmsOfSamples(Float32List samples) {
  if (samples.isEmpty) {
    return 0;
  }
  var sumSquares = 0.0;
  for (final sample in samples) {
    sumSquares += sample * sample;
  }
  final mean = sumSquares / samples.length;
  return mean <= 0 ? 0 : math.sqrt(mean);
}
