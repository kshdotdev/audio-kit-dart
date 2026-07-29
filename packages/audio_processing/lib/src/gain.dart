import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'processor.dart';
import 'rechunker.dart';

/// Slow automatic gain control that amplifies quiet capture and never
/// attenuates loud capture.
///
/// Built for the models sitting downstream of a microphone, not for listeners.
/// Capture levels vary by an order of magnitude across devices and users — real
/// recordings peaking at 0.05 are ordinary — and a speech-probability model
/// trained on normalized audio simply collapses on input that quiet. Scaling
/// toward a target peak restores the range those models expect.
///
/// The running peak decays slowly instead of resetting per chunk, which is what
/// keeps the noise floor from being pumped up between utterances: silence
/// following speech is still measured against the speech that preceded it.
/// Loud input is passed through untouched, so this is never a limiter.
final class AdaptiveGain {
  /// Creates a gain stage.
  AdaptiveGain({this.targetPeak = 0.3, this.maxGain = 30, this.decay = 0.995}) {
    if (!targetPeak.isFinite || targetPeak <= 0) {
      throw ArgumentError.value(
        targetPeak,
        'targetPeak',
        'Must be finite and positive.',
      );
    }
    if (!maxGain.isFinite || maxGain < 1) {
      throw ArgumentError.value(maxGain, 'maxGain', 'Must be at least 1.');
    }
    if (!decay.isFinite || decay <= 0 || decay > 1) {
      throw ArgumentError.value(
        decay,
        'decay',
        'Must be greater than 0 and at most 1.',
      );
    }
  }

  /// Gain below which a chunk is passed through unchanged.
  ///
  /// Healthy levels need no help, and rescaling them by a few percent only
  /// costs an allocation and a copy per chunk.
  static const double deadband = 1.05;

  /// Running peak below which the input counts as silence.
  ///
  /// True silence stays silent: without this floor the maximum gain would be
  /// applied to a numerically empty buffer and amplify only its noise.
  static const double silenceFloor = 1e-6;

  /// Amplitude the running peak is scaled toward.
  final double targetPeak;

  /// Ceiling on the applied gain, about 30 dB at the default.
  final double maxGain;

  /// Running-peak decay applied once per [apply] call.
  ///
  /// A per-chunk constant, not a per-second one: the 0.995 default is a ~35 s
  /// half-life at the 256 ms chunks this was tuned for, and it decays faster in
  /// wall-clock terms when fed smaller chunks. Feed fixed-size chunks — see
  /// [AdaptiveGainProcessor].
  final double decay;

  double _runningPeak = 0;

  /// Current running peak, for diagnostics.
  double get runningPeak => _runningPeak;

  /// Gain the most recent [apply] used, or 1 when the chunk passed through
  /// untouched.
  double get gain {
    if (_runningPeak <= silenceFloor) {
      return 1;
    }
    final gain = targetPeak / _runningPeak;
    final limited = gain < maxGain ? gain : maxGain;
    return limited > deadband ? limited : 1;
  }

  /// Folds [chunk]'s peak into the running peak and returns the scaled chunk.
  ///
  /// Returns [chunk] itself — the identical instance, not a copy — when no gain
  /// is warranted, so the common healthy-level path allocates nothing. The
  /// returned list is never mutated by this class.
  Float32List apply(Float32List chunk) {
    var peak = 0.0;
    for (final sample in chunk) {
      final magnitude = sample.abs();
      if (magnitude > peak) {
        peak = magnitude;
      }
    }
    final decayed = _runningPeak * decay;
    _runningPeak = peak > decayed ? peak : decayed;

    final gain = this.gain;
    if (gain == 1) {
      return chunk;
    }
    final output = Float32List(chunk.length);
    for (var index = 0; index < chunk.length; index += 1) {
      output[index] = chunk[index] * gain;
    }
    return output;
  }

  /// Forgets the running peak, so the next chunk is measured on its own.
  void reset() {
    _runningPeak = 0;
  }
}

/// [AdaptiveGain] as a graph stage, with one gain state per stream.
///
/// Levels belong to a capture device, so tracks are never allowed to share a
/// running peak: a loud system-audio track must not attenuate — or rather, fail
/// to amplify — a quiet microphone beside it.
///
/// [AdaptiveGain.decay] is applied once per frame, so put an
/// [AudioRechunker] upstream when the source emits variable-size frames;
/// otherwise the decay time constant follows whatever the device happens to
/// deliver.
final class AdaptiveGainProcessor implements AudioFrameProcessor {
  /// Creates a processor whose per-stream stages use these parameters.
  AdaptiveGainProcessor({
    this.targetPeak = 0.3,
    this.maxGain = 30,
    this.decay = 0.995,
  });

  /// Amplitude each stream's running peak is scaled toward.
  final double targetPeak;

  /// Ceiling on the applied gain.
  final double maxGain;

  /// Running-peak decay applied once per frame.
  final double decay;

  final Map<AudioStreamKey, AdaptiveGain> _stages =
      <AudioStreamKey, AdaptiveGain>{};

  /// Gain stage for [stream], or null when nothing has been processed for it.
  AdaptiveGain? gainFor(AudioStreamKey stream) => _stages[stream];

  @override
  List<AudioFrame> process(AudioFrame frame) {
    final key = AudioStreamKey.fromFrame(frame);
    if (frame.discontinuity != null) {
      // A restart, a format change, or dropped audio makes the running peak a
      // measurement of a signal that no longer exists.
      _stages.remove(key);
    }
    final stage = _stages.putIfAbsent(
      key,
      () =>
          AdaptiveGain(targetPeak: targetPeak, maxGain: maxGain, decay: decay),
    );

    // Interleaved channels share one gain, which is what keeps a stereo image
    // intact; the peak is taken across the frame either way.
    final scaled = stage.apply(frame.samples);
    if (identical(scaled, frame.samples)) {
      return <AudioFrame>[frame.copyWith()];
    }
    return <AudioFrame>[
      AudioFrame.owned(
        format: frame.format,
        samples: scaled,
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
      _stages.clear();
    } else {
      _stages.remove(stream);
    }
  }
}
