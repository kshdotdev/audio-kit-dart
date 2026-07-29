// Detection fusion and the prompt state machine are derived from Control
// Center's `meeting_detection.dart`, MIT (c) 2026 Samuel Alev. See NOTICE.

/// A kind of observable evidence that a meeting is under way.
///
/// The *sources* of these signals are platform-specific (macOS Core Audio and
/// EventKit, Windows WASAPI sessions, Linux PipeWire, plus a cross-platform
/// calendar), but the fusion in [resolveMeetingCandidate] is pure and portable.
enum MeetingSignalKind {
  /// A known per-meeting conferencing client is running or frontmost.
  conferencingApp,

  /// A browser tab is on a meeting URL.
  browserMeeting,

  /// A calendar event is scheduled to be happening right now.
  calendarEvent,

  /// The camera is in use.
  camera,

  /// The microphone is captured by another application.
  microphoneInUse,

  /// Sustained system audio output — somebody is audibly talking.
  systemAudioActive,

  /// A recording is in progress and speech is still being transcribed.
  ///
  /// The most direct evidence available that a meeting is live. It exists so
  /// the auto-stop suggestion cannot fire while people are still talking.
  activeRecording,
}

/// One observation of a [MeetingSignalKind] at a point in time.
final class MeetingSignal {
  /// Creates a signal observation.
  const MeetingSignal({
    required this.kind,
    required this.active,
    required this.at,
    this.label,
  });

  /// Which signal this is.
  final MeetingSignalKind kind;

  /// Whether the signal is currently asserted.
  final bool active;

  /// When the observation was made, on the caller's shared clock.
  final DateTime at;

  /// Optional human label — application name, URL host, or event title.
  final String? label;
}

/// A resolved likelihood that a meeting is under way.
final class MeetingCandidate {
  /// Creates a candidate.
  const MeetingCandidate({
    required this.confidence,
    required this.primary,
    required this.since,
    this.label,
  });

  /// Fused confidence in the inclusive range 0–1.
  final double confidence;

  /// The strongest contributing signal kind.
  final MeetingSignalKind primary;

  /// The best human label among the active signals.
  final String? label;

  /// Earliest fresh active observation — when the candidate began.
  final DateTime since;
}

/// Per-kind base weights used by [resolveMeetingCandidate].
///
/// Provenance: these values are Control Center's, tuned against its own signal
/// collectors. A strong single signal (a per-meeting conferencing client) is
/// sufficient alone; weak signals corroborate one another. Re-tune them if your
/// collectors differ in reliability — pass a replacement map to
/// [MeetingDetectionPolicy.weights].
const Map<MeetingSignalKind, double> defaultMeetingSignalWeights = {
  MeetingSignalKind.activeRecording: 0.9,
  MeetingSignalKind.conferencingApp: 0.8,
  MeetingSignalKind.browserMeeting: 0.7,
  MeetingSignalKind.calendarEvent: 0.6,
  MeetingSignalKind.camera: 0.4,
  MeetingSignalKind.microphoneInUse: 0.35,
  MeetingSignalKind.systemAudioActive: 0.3,
};

/// Tunable thresholds for detection, prompting, and auto-stop.
///
/// Every default carries Control Center's tuning; they are parameters rather
/// than constants precisely because a different collector set warrants
/// different values.
final class MeetingDetectionPolicy {
  /// Creates a policy.
  const MeetingDetectionPolicy({
    this.freshness = const Duration(seconds: 20),
    this.minPresence = const Duration(seconds: 8),
    this.autoStopAfter = const Duration(seconds: 90),
    this.threshold = 0.6,
    this.corroborationBonus = 0.15,
    this.weights = defaultMeetingSignalWeights,
  });

  /// Signals older than this, relative to `now`, are ignored.
  final Duration freshness;

  /// How long a candidate must persist before a prompt is offered.
  ///
  /// Debounces a brief blip — a notification sound, or opening a client by
  /// accident.
  final Duration minPresence;

  /// How long without a fresh candidate, while recording, before the meeting is
  /// judged to have ended.
  final Duration autoStopAfter;

  /// Minimum fused confidence for a candidate to exist at all.
  final double threshold;

  /// Confidence added per additional distinct active signal kind.
  final double corroborationBonus;

  /// Per-kind base weights.
  final Map<MeetingSignalKind, double> weights;
}

/// Fuses recent [signals] into a [MeetingCandidate], or returns null when the
/// evidence falls below [MeetingDetectionPolicy.threshold].
///
/// Confidence is the strongest active fresh signal's weight plus
/// [MeetingDetectionPolicy.corroborationBonus] per additional distinct active
/// kind, clamped to 1. The label and primary come from the highest-weight
/// active signal.
///
/// Pure and deterministic — [now] is supplied by the caller — so the whole
/// detection policy is unit-testable.
MeetingCandidate? resolveMeetingCandidate(
  Iterable<MeetingSignal> signals, {
  required DateTime now,
  MeetingDetectionPolicy policy = const MeetingDetectionPolicy(),
}) {
  final latest = <MeetingSignalKind, MeetingSignal>{};
  for (final signal in signals) {
    if (!signal.active) {
      continue;
    }
    if (now.difference(signal.at) > policy.freshness ||
        signal.at.isAfter(now)) {
      continue;
    }
    final previous = latest[signal.kind];
    if (previous == null || signal.at.isAfter(previous.at)) {
      latest[signal.kind] = signal;
    }
  }
  if (latest.isEmpty) {
    return null;
  }

  MeetingSignalKind? best;
  var bestWeight = 0.0;
  for (final kind in latest.keys) {
    final weight = policy.weights[kind] ?? 0;
    if (weight > bestWeight) {
      bestWeight = weight;
      best = kind;
    }
  }
  if (best == null) {
    return null;
  }

  final corroboration = (latest.length - 1) * policy.corroborationBonus;
  final confidence = (bestWeight + corroboration).clamp(0.0, 1.0);
  if (confidence < policy.threshold) {
    return null;
  }
  final since = latest.values
      .map((signal) => signal.at)
      .reduce((a, b) => a.isBefore(b) ? a : b);
  return MeetingCandidate(
    confidence: confidence,
    primary: best,
    label: latest[best]?.label,
    since: since,
  );
}

/// Lifecycle state of the auto-detection prompt machine.
enum MeetingDetectionState {
  /// No candidate.
  idle,

  /// A candidate exists but has not yet persisted for
  /// [MeetingDetectionPolicy.minPresence].
  watching,

  /// A prompt is being shown.
  prompting,

  /// The user accepted — a recording is in progress.
  recording,
}

/// What the host should do in response to [MeetingDetectionStateMachine.update].
enum MeetingDetectionAction {
  /// Nothing to do.
  none,

  /// Show the "record this meeting?" prompt.
  showPrompt,

  /// Hide the prompt — the candidate vanished before the user answered.
  hidePrompt,

  /// Suggest stopping; the meeting appears to have ended.
  suggestAutoStop,
}

/// A pure, time-driven state machine turning a stream of [MeetingCandidate]
/// resolutions into prompt and auto-stop actions.
///
/// Debounces with a minimum presence window, suppresses a dismissed candidate
/// until it clears, and suggests auto-stop after a sustained no-signal gap. The
/// host drives it by calling [update] whenever signals change (or on a timer)
/// and reports user choices through [accept], [dismiss], and [stopped].
final class MeetingDetectionStateMachine {
  /// Creates a machine governed by [policy].
  MeetingDetectionStateMachine({this.policy = const MeetingDetectionPolicy()});

  /// Detection thresholds.
  final MeetingDetectionPolicy policy;

  MeetingDetectionState _state = MeetingDetectionState.idle;
  DateTime? _candidateSince;
  DateTime? _lastCandidateAt;
  String? _dismissedLabel;

  /// Current state.
  MeetingDetectionState get state => _state;

  /// Advances the machine with the latest resolved [candidate] at [now].
  MeetingDetectionAction update({
    required MeetingCandidate? candidate,
    required DateTime now,
  }) {
    if (candidate != null) {
      _lastCandidateAt = now;
    }

    switch (_state) {
      case MeetingDetectionState.recording:
        final last = _lastCandidateAt;
        if (candidate == null &&
            last != null &&
            now.difference(last) >= policy.autoStopAfter) {
          return MeetingDetectionAction.suggestAutoStop;
        }
        return MeetingDetectionAction.none;

      case MeetingDetectionState.idle:
      case MeetingDetectionState.watching:
      case MeetingDetectionState.prompting:
        if (candidate == null) {
          final wasPrompting = _state == MeetingDetectionState.prompting;
          _resetToIdle();
          return wasPrompting
              ? MeetingDetectionAction.hidePrompt
              : MeetingDetectionAction.none;
        }
        if (_dismissedLabel != null && _dismissedLabel == candidate.label) {
          _state = MeetingDetectionState.watching;
          return MeetingDetectionAction.none;
        }
        _candidateSince ??= candidate.since;
        final persisted =
            now.difference(_candidateSince!) >= policy.minPresence;
        if (persisted) {
          if (_state != MeetingDetectionState.prompting) {
            _state = MeetingDetectionState.prompting;
            return MeetingDetectionAction.showPrompt;
          }
          return MeetingDetectionAction.none;
        }
        _state = MeetingDetectionState.watching;
        return MeetingDetectionAction.none;
    }
  }

  /// The user accepted the prompt — a recording has started.
  void accept() {
    _state = MeetingDetectionState.recording;
    _dismissedLabel = null;
  }

  /// The user dismissed the prompt for [label]; suppress it until it clears.
  void dismiss(String? label) {
    _dismissedLabel = label;
    _state = MeetingDetectionState.watching;
    _candidateSince = null;
  }

  /// The recording stopped — return to idle detection.
  void stopped() => _resetToIdle();

  void _resetToIdle() {
    _state = MeetingDetectionState.idle;
    _candidateSince = null;
    _dismissedLabel = null;
  }
}
