// The dead-mic heuristic and its tuning are derived from Control Center's
// `meeting_mic_health.dart`, MIT (c) 2026 Samuel Alev. See NOTICE.

import 'package:audio_processing/audio_processing.dart';

/// Health verdict for microphone capture during a recording.
enum MicHealth {
  /// The microphone is delivering audio, or there is nothing to compare
  /// against yet.
  ok,

  /// The far side is clearly audible while the near microphone has been silent
  /// for a sustained window.
  ///
  /// A strong indication the microphone is muted, dead, or held by another
  /// application — worth warning about mid-call, before the user loses their
  /// own half of the conversation.
  silentWhileFarActive,
}

/// Tracks near and far channel levels to detect a dead or muted microphone.
///
/// A microphone that stays silent while the far end is plainly talking is
/// almost always broken rather than merely listening. Pure — time is passed in
/// — so it is deterministic and unit-testable.
///
/// This deliberately does not compute RMS itself. Feed it readings from
/// [AudioMeter], which already measures every frame:
///
/// ```dart
/// final reading = meter.process(frame);
/// tracker.noteNearReading(reading);
/// ```
///
/// All amplitude thresholds are on the normalized 0–1 scale, matching both
/// [AudioMeterReading.rms] and the float32 sample range used throughout the
/// SDK.
final class MicHealthTracker {
  /// Creates a tracker.
  ///
  /// Provenance: the defaults are Control Center's, tuned for 16 kHz mono
  /// speech. Its own RMS helper divided PCM16 samples by 32768 before
  /// measuring, so these floors were already normalized and carry over to
  /// float32 unchanged.
  MicHealthTracker({
    this.nearFloor = 0.01,
    this.farFloor = 0.02,
    this.confirmAfter = const Duration(seconds: 3),
    this.farRecencyWindow = const Duration(seconds: 2),
    this.levelSmoothing = 0.4,
  }) {
    if (nearFloor < 0 || nearFloor > 1) {
      throw ArgumentError.value(nearFloor, 'nearFloor', 'Must be within 0–1.');
    }
    if (farFloor < 0 || farFloor > 1) {
      throw ArgumentError.value(farFloor, 'farFloor', 'Must be within 0–1.');
    }
    if (levelSmoothing <= 0 || levelSmoothing > 1) {
      throw ArgumentError.value(
        levelSmoothing,
        'levelSmoothing',
        'Must be within 0 (exclusive) and 1.',
      );
    }
    if (confirmAfter <= Duration.zero) {
      throw ArgumentError.value(
        confirmAfter,
        'confirmAfter',
        'Must be positive.',
      );
    }
    if (farRecencyWindow <= Duration.zero) {
      throw ArgumentError.value(
        farRecencyWindow,
        'farRecencyWindow',
        'Must be positive.',
      );
    }
  }

  /// Normalized RMS above which the near channel counts as carrying speech.
  final double nearFloor;

  /// Normalized RMS above which the far channel counts as actively playing.
  final double farFloor;

  /// How long the near channel must stay below [nearFloor], while the far
  /// channel is active, before the microphone is reported silent.
  final Duration confirmAfter;

  /// How recently the far channel must have been active for the silent-mic
  /// check to apply, so a finished remote turn does not hold the warning up.
  final Duration farRecencyWindow;

  /// Exponential-moving-average factor for [level]; higher is snappier.
  final double levelSmoothing;

  Duration? _lastAt;
  Duration? _lastNearAboveFloor;
  Duration? _lastFarActive;
  Duration? _firstNearAt;
  double _level = 0;

  /// Smoothed near-channel level in 0–1, suitable for an amplitude meter.
  double get level => _level;

  /// Records a near (microphone) chunk's normalized [rms] stamped at [at].
  void noteNear(double rms, Duration at) {
    _lastAt = at;
    _firstNearAt ??= at;
    _level += (rms.clamp(0.0, 1.0) - _level) * levelSmoothing;
    if (rms >= nearFloor) {
      _lastNearAboveFloor = at;
    }
  }

  /// Records a far (system) chunk's normalized [rms] stamped at [at].
  void noteFar(double rms, Duration at) {
    final last = _lastAt;
    if (last == null || at > last) {
      _lastAt = at;
    }
    if (rms >= farFloor) {
      _lastFarActive = at;
    }
  }

  /// Records a near-channel [reading] produced by [AudioMeter].
  void noteNearReading(AudioMeterReading reading) =>
      noteNear(reading.rms, reading.timestamp);

  /// Records a far-channel [reading] produced by [AudioMeter].
  void noteFarReading(AudioMeterReading reading) =>
      noteFar(reading.rms, reading.timestamp);

  /// The verdict as of the latest stamped time.
  MicHealth get health {
    final now = _lastAt;
    final farActiveAt = _lastFarActive;
    if (now == null || farActiveAt == null) {
      return MicHealth.ok;
    }
    if (now - farActiveAt > farRecencyWindow) {
      return MicHealth.ok;
    }
    // Silence is measured from the last time the near channel rose above the
    // floor, or from its first sample when it never has.
    final since = _lastNearAboveFloor ?? _firstNearAt;
    if (since == null) {
      return MicHealth.ok;
    }
    return now - since >= confirmAfter
        ? MicHealth.silentWhileFarActive
        : MicHealth.ok;
  }

  /// Whether the microphone appears dead or muted while the far end talks.
  bool get isNearSilentWhileFarActive =>
      health == MicHealth.silentWhileFarActive;

  /// Clears all state for a new recording.
  void reset() {
    _lastAt = null;
    _lastNearAboveFloor = null;
    _lastFarActive = null;
    _firstNearAt = null;
    _level = 0;
  }
}
