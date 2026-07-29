// The lifecycle statuses and the reconciler pattern (single finalizer plus a
// startup sweep) are derived from Control Center's `meeting_recording_session.dart`
// and `meeting_summary_reconciler.dart`, MIT (c) 2026 Samuel Alev. See NOTICE.

import 'dart:async';

/// Lifecycle status of a recorded meeting.
enum MeetingStatus {
  /// Audio is being captured and transcribed live.
  recording,

  /// Capture stopped; post-processing is augmenting the record.
  processing,

  /// The record is finalized.
  done,

  /// Recording or post-processing failed.
  failed;

  /// Whether this status is terminal — nothing further will move it.
  bool get isTerminal =>
      this == MeetingStatus.done || this == MeetingStatus.failed;
}

/// Thrown when a lifecycle transition is not permitted.
final class MeetingTransitionError extends StateError {
  /// Creates an error describing a rejected transition.
  MeetingTransitionError(this.from, this.to)
    : super('Cannot move a meeting from ${from.name} to ${to.name}.');

  /// The status the meeting was in.
  final MeetingStatus from;

  /// The status that was requested.
  final MeetingStatus to;
}

/// The transitions the lifecycle permits.
///
/// `recording → processing | failed`, `processing → done | failed`. Terminal
/// statuses do not move.
const Map<MeetingStatus, Set<MeetingStatus>> allowedMeetingTransitions = {
  MeetingStatus.recording: {MeetingStatus.processing, MeetingStatus.failed},
  MeetingStatus.processing: {MeetingStatus.done, MeetingStatus.failed},
  MeetingStatus.done: <MeetingStatus>{},
  MeetingStatus.failed: <MeetingStatus>{},
};

/// Whether moving from [from] to [to] is permitted.
bool canTransitionMeeting(MeetingStatus from, MeetingStatus to) =>
    allowedMeetingTransitions[from]?.contains(to) ?? false;

/// One meeting's lifecycle state.
///
/// Deliberately minimal: an identifier, a status, and whether any transcript
/// was captured. Persistence, titles, notes, and summaries belong to the host —
/// see [MeetingStore].
final class MeetingLifecycleRecord {
  /// Creates a record.
  const MeetingLifecycleRecord({
    required this.id,
    required this.status,
    this.hasTranscript = false,
  });

  /// Stable identifier assigned by the host.
  final String id;

  /// Current status.
  final MeetingStatus status;

  /// Whether any transcript survived capture.
  ///
  /// The reconciler uses this to decide between recovering a stranded recording
  /// into post-processing and failing it outright.
  final bool hasTranscript;

  /// Returns a copy with the given overrides.
  MeetingLifecycleRecord copyWith({
    MeetingStatus? status,
    bool? hasTranscript,
  }) => MeetingLifecycleRecord(
    id: id,
    status: status ?? this.status,
    hasTranscript: hasTranscript ?? this.hasTranscript,
  );
}

/// Persistence seam for meeting lifecycle state.
///
/// The SDK owns the state machine and the recovery policy; the host owns the
/// database. Implementations must be safe to call concurrently for distinct
/// meeting identifiers.
abstract interface class MeetingStore {
  /// Returns the meeting with [id], or null when it is unknown.
  Future<MeetingLifecycleRecord?> read(String id);

  /// Returns every meeting whose status is not terminal.
  Future<List<MeetingLifecycleRecord>> readUnfinalized();

  /// Writes [record].
  Future<void> write(MeetingLifecycleRecord record);
}

/// Drives meetings through [MeetingStatus] and enforces the allowed
/// transitions.
///
/// Concurrent recordings are supported: every operation is keyed by meeting
/// identifier and the lifecycle holds no single-session state.
final class MeetingLifecycle {
  /// Creates a lifecycle over [store].
  MeetingLifecycle({required this.store});

  /// Where lifecycle state is persisted.
  final MeetingStore store;

  /// Registers a new meeting in [MeetingStatus.recording].
  Future<MeetingLifecycleRecord> begin(String id) async {
    final record = MeetingLifecycleRecord(
      id: id,
      status: MeetingStatus.recording,
    );
    await store.write(record);
    return record;
  }

  /// Records that [id] captured transcript content.
  Future<void> markTranscribed(String id) async {
    final record = await _require(id);
    if (record.hasTranscript) {
      return;
    }
    await store.write(record.copyWith(hasTranscript: true));
  }

  /// Moves [id] from recording into post-processing.
  Future<MeetingLifecycleRecord> stopCapture(String id) =>
      _transition(id, MeetingStatus.processing);

  /// Finalizes [id].
  Future<MeetingLifecycleRecord> finalizeDone(String id) =>
      _transition(id, MeetingStatus.done);

  /// Fails [id].
  Future<MeetingLifecycleRecord> fail(String id) =>
      _transition(id, MeetingStatus.failed);

  Future<MeetingLifecycleRecord> _transition(
    String id,
    MeetingStatus next,
  ) async {
    final record = await _require(id);
    if (!canTransitionMeeting(record.status, next)) {
      throw MeetingTransitionError(record.status, next);
    }
    final updated = record.copyWith(status: next);
    await store.write(updated);
    return updated;
  }

  Future<MeetingLifecycleRecord> _require(String id) async {
    final record = await store.read(id);
    if (record == null) {
      throw StateError('Unknown meeting: $id.');
    }
    return record;
  }
}

/// How a post-processing run ended.
enum MeetingProcessingOutcomeKind {
  /// The run completed.
  completed,

  /// The run failed.
  failed,

  /// The run was cancelled.
  cancelled,
}

/// A terminal post-processing event for one meeting.
final class MeetingProcessingOutcome {
  /// Creates an outcome.
  const MeetingProcessingOutcome({required this.meetingId, required this.kind});

  /// Which meeting the run belonged to.
  final String meetingId;

  /// How the run ended.
  final MeetingProcessingOutcomeKind kind;
}

/// Keeps meetings from getting stuck in a non-terminal status.
///
/// A meeting is non-terminal while [MeetingStatus.recording] (capture in
/// progress) or [MeetingStatus.processing] (post-processing under way), and
/// either can be stranded by a crash or a killed process. This reconciler is
/// the single place that drives every meeting to a terminal status, for two
/// reasons:
///
///  * **One finalizer.** No post-processing step flips a meeting to
///    [MeetingStatus.done] itself, so a single failed step cannot strand a
///    half-written meeting that is already marked finished. Instead every
///    terminal event — completed, failed, *or cancelled* — routes through
///    [handleOutcome].
///  * **A startup sweep.** [sweep] catches meetings stranded by a previous
///    session. No capture survives a restart, so a meeting still marked
///    recording was interrupted before its stop ran; it is recovered exactly as
///    a graceful stop would be. A meeting left processing is finalized unless
///    the host reports its run still active.
final class MeetingReconciler {
  /// Creates a reconciler.
  ///
  /// [isProcessingActive] lets the host veto finalizing a meeting whose
  /// post-processing genuinely is still running; that run finalizes it through
  /// its own terminal event instead. It defaults to reporting nothing active.
  MeetingReconciler({
    required this.lifecycle,
    Future<bool> Function(String meetingId)? isProcessingActive,
  }) : _isProcessingActive = isProcessingActive ?? _noneActive;

  /// The lifecycle being reconciled.
  final MeetingLifecycle lifecycle;

  final Future<bool> Function(String meetingId) _isProcessingActive;

  /// Applies a terminal post-processing [outcome].
  ///
  /// A meeting still in [MeetingStatus.processing] is finalized: to
  /// [MeetingStatus.done] when the run completed or was cancelled — a cancelled
  /// run still leaves whatever was captured, which must not be lost — and to
  /// [MeetingStatus.failed] when it failed without a transcript. Anything
  /// already terminal is left alone.
  Future<void> handleOutcome(MeetingProcessingOutcome outcome) async {
    final record = await lifecycle.store.read(outcome.meetingId);
    if (record == null || record.status != MeetingStatus.processing) {
      return;
    }
    final failedWithoutContent =
        outcome.kind == MeetingProcessingOutcomeKind.failed &&
        !record.hasTranscript;
    if (failedWithoutContent) {
      await lifecycle.fail(outcome.meetingId);
      return;
    }
    await lifecycle.finalizeDone(outcome.meetingId);
  }

  /// Sweeps every non-terminal meeting, rescuing those stranded by a previous
  /// session. Returns the meetings it moved.
  Future<List<MeetingLifecycleRecord>> sweep() async {
    final stranded = await lifecycle.store.readUnfinalized();
    final moved = <MeetingLifecycleRecord>[];
    for (final record in stranded) {
      switch (record.status) {
        case MeetingStatus.recording:
          // Capture cannot have survived; recover it like a graceful stop.
          final processing = await lifecycle.stopCapture(record.id);
          moved.add(
            record.hasTranscript
                ? processing
                : await lifecycle.finalizeDone(record.id),
          );
        case MeetingStatus.processing:
          if (await _isProcessingActive(record.id)) {
            continue;
          }
          moved.add(await lifecycle.finalizeDone(record.id));
        case MeetingStatus.done:
        case MeetingStatus.failed:
          continue;
      }
    }
    return moved;
  }

  static Future<bool> _noneActive(String _) async => false;
}
