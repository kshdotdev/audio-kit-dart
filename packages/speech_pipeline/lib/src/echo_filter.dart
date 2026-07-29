import 'dart:async';
import 'dart:math' as math;

import 'transcript_segment.dart';

// Derived from Control Center's `meeting_echo_filter.dart`
// (MIT © 2026 Samuel Alev). Adapted to emit a stream of accepted segments
// rather than invoking a persistence callback, and to take an injectable hold
// scheduler so the adaptive holds are testable without real time. See NOTICE.

/// Which side of a two-track capture produced a transcript window.
enum EchoTrackRole {
  /// The local microphone track — the one that can re-hear the far side.
  near,

  /// The system-output (remote party) track. Authoritative: never dropped.
  far,
}

/// A transcribed window offered to a [TranscriptEchoFilter], tagged with its
/// role and an emit time drawn from the single clock shared by both tracks —
/// the only timeline on which the two are comparable.
final class EchoCandidate {
  /// Creates a candidate.
  EchoCandidate({
    required this.role,
    required this.segment,
    required this.emitTime,
  }) {
    if (emitTime.isNegative) {
      throw ArgumentError.value(emitTime, 'emitTime', 'Must not be negative.');
    }
  }

  /// Which track produced this window.
  final EchoTrackRole role;

  /// The decoded window.
  final TranscriptSegment segment;

  /// Emit time on the shared clock.
  final Duration emitTime;
}

/// Schedules a delayed [callback], returning a cancellable timer.
///
/// Defaults to [Timer.new]; tests inject a controllable implementation.
typedef EchoHoldScheduler =
    Timer Function(Duration delay, void Function() callback);

/// Removes duplicate near-track windows that arise when the microphone picks up
/// the far party playing out of speakers or headphones.
///
/// The system-output track never captures the microphone, so the far track is
/// always the authoritative copy and the microphone echo is a degraded,
/// fragmented duplicate. Resolution is therefore strictly one-directional: a
/// near window matching a near-contemporaneous far window is dropped, and far
/// windows are never dropped, held, or reordered.
///
/// Ordering is handled both ways. A far window commits immediately and is
/// buffered, so a later near echo is dropped on arrival. A near window with no
/// match yet is *held*, so a still-incoming far window can cancel it. The hold
/// is adaptive (see [noteFarActivity]): long ([activeHold]) while the far side
/// is playing — the authoritative far window is longer and arrives seconds
/// later, so the hold must outlast that lag — and brief ([idleHold]) while the
/// far side is quiet, when no echo is possible.
///
/// The invariant `activeHold >= matchWindow` guarantees a held near window
/// never commits before a same-band far window could cancel it.
final class TranscriptEchoFilter {
  /// Creates a filter.
  TranscriptEchoFilter({
    this.idleHold = const Duration(milliseconds: 700),
    this.activeHold = const Duration(milliseconds: 7000),
    this.activeWindow = const Duration(milliseconds: 2500),
    this.buffer = const Duration(milliseconds: 11000),
    this.matchWindow = const Duration(milliseconds: 7000),
    this.similarityThreshold = 0.6,
    this.minTokens = 3,
    EchoHoldScheduler? scheduler,
  }) : _scheduler = scheduler ?? Timer.new {
    if (activeHold < matchWindow) {
      throw ArgumentError.value(
        activeHold,
        'activeHold',
        'Must be >= matchWindow so a held near window cannot commit before a '
            'same-band far window could cancel it.',
      );
    }
    if (!similarityThreshold.isFinite ||
        similarityThreshold < 0 ||
        similarityThreshold > 1) {
      throw ArgumentError.value(
        similarityThreshold,
        'similarityThreshold',
        'Must be between 0 and 1.',
      );
    }
    if (minTokens < 1) {
      throw ArgumentError.value(minTokens, 'minTokens', 'Must be positive.');
    }
  }

  /// Brief debounce before committing a near window emitted while the far side
  /// was quiet — no echo is possible, so it commits almost immediately.
  final Duration idleHold;

  /// Long debounce for a near window emitted while the far side was recently
  /// playing: held until its late, longer far source could arrive and cancel it.
  final Duration activeHold;

  /// How recently the far track must have had audio for a near window to be
  /// treated as echo-possible.
  final Duration activeWindow;

  /// Retention window for recent far windows.
  final Duration buffer;

  /// Emit-time band within which a near window can match a far window.
  final Duration matchWindow;

  /// Containment-similarity threshold (0–1) for a match.
  final double similarityThreshold;

  /// Windows with fewer tokens than this are never matched as echoes, which
  /// protects backchannels like "okay" and "yeah".
  final int minTokens;

  final EchoHoldScheduler _scheduler;
  final StreamController<TranscriptSegment> _accepted =
      StreamController<TranscriptSegment>.broadcast();
  final List<_BufferedWindow> _recentFar = <_BufferedWindow>[];
  final List<_PendingNear> _pendingNear = <_PendingNear>[];

  Duration? _lastFarActivity;
  bool _disposed = false;

  /// Segments the filter judged genuine, in commit order.
  Stream<TranscriptSegment> get accepted => _accepted.stream;

  /// Number of near windows currently held awaiting a possible far match.
  int get pendingCount => _pendingNear.length;

  /// Records that the far track had audio at [emitTime] on the shared clock.
  ///
  /// Cheap enough to call per active far chunk. A near window emitted within
  /// [activeWindow] of the latest activity is treated as echo-possible.
  void noteFarActivity(Duration emitTime) {
    if (_disposed) {
      return;
    }
    final last = _lastFarActivity;
    if (last == null || emitTime > last) {
      _lastFarActivity = emitTime;
    }
  }

  /// Offers [candidate] to the filter.
  void add(EchoCandidate candidate) {
    if (_disposed) {
      return;
    }
    _pruneFar(candidate.emitTime);
    final tokens = echoTokens(candidate.segment.text).toSet();
    if (candidate.role == EchoTrackRole.far) {
      _acceptFar(candidate, tokens);
    } else {
      _offerNear(candidate, tokens);
    }
  }

  void _acceptFar(EchoCandidate candidate, Set<String> tokens) {
    // Authoritative: emit immediately, never held or dropped.
    _commit(candidate);
    final buffered = _BufferedWindow(candidate.emitTime, tokens);
    _recentFar.add(buffered);
    // A near window held earlier may be an echo of this just-arrived far one.
    _pendingNear.removeWhere((pending) {
      final similarity = _echoSimilarity(
        pending.candidate.emitTime,
        pending.tokens,
        buffered,
      );
      if (similarity != null) {
        pending.timer.cancel();
        return true;
      }
      return false;
    });
  }

  void _offerNear(EchoCandidate candidate, Set<String> tokens) {
    for (final far in _recentFar) {
      if (_echoSimilarity(candidate.emitTime, tokens, far) != null) {
        return; // Echo of a buffered far window — drop now.
      }
    }
    // No match yet: hold so a still-incoming far window can cancel it. If the
    // far side was playing when this was emitted it may be bleed whose late,
    // longer source has not arrived — hold long. Otherwise commit promptly.
    final last = _lastFarActivity;
    final echoPossible =
        last != null && (candidate.emitTime - last) <= activeWindow;
    final hold = echoPossible ? activeHold : idleHold;
    late _PendingNear pending;
    final timer = _scheduler(hold, () {
      _pendingNear.remove(pending);
      _commit(candidate);
    });
    pending = _PendingNear(candidate, tokens, timer);
    _pendingNear.add(pending);
  }

  /// Returns the match similarity when the near window described by
  /// [nearEmitTime] and [nearTokens] is an echo of [far], or null when not.
  double? _echoSimilarity(
    Duration nearEmitTime,
    Set<String> nearTokens,
    _BufferedWindow far,
  ) {
    final delta = nearEmitTime - far.emitTime;
    if (delta.abs() > matchWindow) {
      return null;
    }
    if (nearTokens.length < minTokens || far.tokens.length < minTokens) {
      return null;
    }
    final similarity = echoSimilarity(nearTokens, far.tokens);
    return similarity >= similarityThreshold ? similarity : null;
  }

  /// Commits every held near window immediately.
  ///
  /// Called when a capture stops so the tail of the recording is not lost.
  void drain() {
    if (_disposed) {
      return;
    }
    final pending = List<_PendingNear>.of(_pendingNear);
    _pendingNear.clear();
    for (final entry in pending) {
      entry.timer.cancel();
      _commit(entry.candidate);
    }
    _recentFar.clear();
  }

  /// Hard teardown: cancels held windows without committing them.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final entry in _pendingNear) {
      entry.timer.cancel();
    }
    _pendingNear.clear();
    _recentFar.clear();
    await _accepted.close();
  }

  void _commit(EchoCandidate candidate) {
    if (!_accepted.isClosed) {
      _accepted.add(candidate.segment);
    }
  }

  void _pruneFar(Duration now) {
    _recentFar.removeWhere((far) => far.emitTime < now - buffer);
  }
}

final class _BufferedWindow {
  _BufferedWindow(this.emitTime, this.tokens);

  final Duration emitTime;
  final Set<String> tokens;
}

final class _PendingNear {
  _PendingNear(this.candidate, this.tokens, this.timer);

  final EchoCandidate candidate;
  final Set<String> tokens;
  final Timer timer;
}

final RegExp _nonTokenCharacters = RegExp('[^a-z0-9 ]');
final RegExp _whitespaceRun = RegExp(r'\s+');

/// Normalizes [text] to comparable tokens: lowercased, punctuation folded out,
/// split on whitespace.
///
/// Both tracks are processed identically, so the representation only has to be
/// consistent, not linguistically perfect — recognizer punctuation is not
/// reliable enough to compare on.
List<String> echoTokens(String text) {
  final cleaned = text.toLowerCase().replaceAll(_nonTokenCharacters, ' ');
  return cleaned
      .split(_whitespaceRun)
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
}

/// Containment (overlap) coefficient: `|a ∩ b| / min(|a|, |b|)`.
///
/// Deliberately not Jaccard. The microphone echo is usually a *fragment* of the
/// longer far-track line, and Jaccard under-scores fragments; containment
/// scores a clean subset 1.0 in either direction.
double echoSimilarity(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) {
    return 0;
  }
  final intersection = a.intersection(b).length;
  final denominator = math.min(a.length, b.length);
  return denominator == 0 ? 0 : intersection / denominator;
}

/// Whether [a] and [b] are similar enough to be the same utterance.
bool isEchoMatch(Set<String> a, Set<String> b, {double threshold = 0.6}) {
  if (a.isEmpty || b.isEmpty) {
    return false;
  }
  return echoSimilarity(a, b) >= threshold;
}
