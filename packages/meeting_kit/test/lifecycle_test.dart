// Reconciler behaviour ported from Control Center's meeting_summary_reconciler,
// MIT (c) 2026 Samuel Alev. See NOTICE.

import 'package:meeting_kit/meeting_kit.dart';
import 'package:test/test.dart';

/// An in-memory [MeetingStore] standing in for the host's database.
final class FakeMeetingStore implements MeetingStore {
  final Map<String, MeetingLifecycleRecord> records = {};
  final List<MeetingStatus> writes = [];

  @override
  Future<MeetingLifecycleRecord?> read(String id) async => records[id];

  @override
  Future<List<MeetingLifecycleRecord>> readUnfinalized() async =>
      records.values.where((r) => !r.status.isTerminal).toList();

  @override
  Future<void> write(MeetingLifecycleRecord record) async {
    records[record.id] = record;
    writes.add(record.status);
  }

  void seed(MeetingLifecycleRecord record) => records[record.id] = record;
}

void main() {
  group('transitions', () {
    test('permits the documented moves only', () {
      expect(
        canTransitionMeeting(MeetingStatus.recording, MeetingStatus.processing),
        isTrue,
      );
      expect(
        canTransitionMeeting(MeetingStatus.processing, MeetingStatus.done),
        isTrue,
      );
      expect(
        canTransitionMeeting(MeetingStatus.recording, MeetingStatus.done),
        isFalse,
      );
      expect(
        canTransitionMeeting(MeetingStatus.done, MeetingStatus.processing),
        isFalse,
      );
    });

    test('marks terminal statuses', () {
      expect(MeetingStatus.done.isTerminal, isTrue);
      expect(MeetingStatus.failed.isTerminal, isTrue);
      expect(MeetingStatus.recording.isTerminal, isFalse);
      expect(MeetingStatus.processing.isTerminal, isFalse);
    });
  });

  group('MeetingLifecycle', () {
    late FakeMeetingStore store;
    late MeetingLifecycle lifecycle;

    setUp(() {
      store = FakeMeetingStore();
      lifecycle = MeetingLifecycle(store: store);
    });

    test('drives a meeting from recording to done', () async {
      await lifecycle.begin('m1');
      expect(store.records['m1']!.status, MeetingStatus.recording);

      await lifecycle.stopCapture('m1');
      expect(store.records['m1']!.status, MeetingStatus.processing);

      await lifecycle.finalizeDone('m1');
      expect(store.records['m1']!.status, MeetingStatus.done);
    });

    test('rejects an illegal transition', () async {
      await lifecycle.begin('m1');
      expect(
        () => lifecycle.finalizeDone('m1'),
        throwsA(isA<MeetingTransitionError>()),
      );
    });

    test('rejects an unknown meeting', () {
      expect(() => lifecycle.stopCapture('nope'), throwsStateError);
    });

    test('supports concurrent meetings independently', () async {
      await lifecycle.begin('a');
      await lifecycle.begin('b');
      await lifecycle.stopCapture('a');

      expect(store.records['a']!.status, MeetingStatus.processing);
      expect(store.records['b']!.status, MeetingStatus.recording);
    });

    test('marks transcript content once', () async {
      await lifecycle.begin('m1');
      await lifecycle.markTranscribed('m1');
      final writesAfterFirst = store.writes.length;

      await lifecycle.markTranscribed('m1');

      expect(store.records['m1']!.hasTranscript, isTrue);
      expect(store.writes.length, writesAfterFirst);
    });

    test('can fail from either non-terminal status', () async {
      await lifecycle.begin('a');
      await lifecycle.fail('a');
      expect(store.records['a']!.status, MeetingStatus.failed);

      await lifecycle.begin('b');
      await lifecycle.stopCapture('b');
      await lifecycle.fail('b');
      expect(store.records['b']!.status, MeetingStatus.failed);
    });
  });

  group('MeetingReconciler.handleOutcome', () {
    late FakeMeetingStore store;
    late MeetingReconciler reconciler;

    setUp(() {
      store = FakeMeetingStore();
      reconciler = MeetingReconciler(lifecycle: MeetingLifecycle(store: store));
    });

    test('finalizes a completed run', () async {
      store.seed(
        const MeetingLifecycleRecord(
          id: 'm1',
          status: MeetingStatus.processing,
        ),
      );

      await reconciler.handleOutcome(
        const MeetingProcessingOutcome(
          meetingId: 'm1',
          kind: MeetingProcessingOutcomeKind.completed,
        ),
      );

      expect(store.records['m1']!.status, MeetingStatus.done);
    });

    test('finalizes a cancelled run so captured work is not lost', () async {
      store.seed(
        const MeetingLifecycleRecord(
          id: 'm1',
          status: MeetingStatus.processing,
        ),
      );

      await reconciler.handleOutcome(
        const MeetingProcessingOutcome(
          meetingId: 'm1',
          kind: MeetingProcessingOutcomeKind.cancelled,
        ),
      );

      expect(store.records['m1']!.status, MeetingStatus.done);
    });

    test('keeps a failed run that still captured a transcript', () async {
      store.seed(
        const MeetingLifecycleRecord(
          id: 'm1',
          status: MeetingStatus.processing,
          hasTranscript: true,
        ),
      );

      await reconciler.handleOutcome(
        const MeetingProcessingOutcome(
          meetingId: 'm1',
          kind: MeetingProcessingOutcomeKind.failed,
        ),
      );

      expect(store.records['m1']!.status, MeetingStatus.done);
    });

    test('fails a run that produced nothing', () async {
      store.seed(
        const MeetingLifecycleRecord(
          id: 'm1',
          status: MeetingStatus.processing,
        ),
      );

      await reconciler.handleOutcome(
        const MeetingProcessingOutcome(
          meetingId: 'm1',
          kind: MeetingProcessingOutcomeKind.failed,
        ),
      );

      expect(store.records['m1']!.status, MeetingStatus.failed);
    });

    test('leaves an already-terminal meeting alone', () async {
      store.seed(
        const MeetingLifecycleRecord(id: 'm1', status: MeetingStatus.done),
      );

      await reconciler.handleOutcome(
        const MeetingProcessingOutcome(
          meetingId: 'm1',
          kind: MeetingProcessingOutcomeKind.failed,
        ),
      );

      expect(store.records['m1']!.status, MeetingStatus.done);
    });

    test('ignores an unknown meeting', () async {
      await reconciler.handleOutcome(
        const MeetingProcessingOutcome(
          meetingId: 'ghost',
          kind: MeetingProcessingOutcomeKind.completed,
        ),
      );

      expect(store.records, isEmpty);
    });
  });

  group('MeetingReconciler.sweep', () {
    test('recovers a stranded recording that captured speech', () async {
      final store = FakeMeetingStore()
        ..seed(
          const MeetingLifecycleRecord(
            id: 'm1',
            status: MeetingStatus.recording,
            hasTranscript: true,
          ),
        );
      final reconciler = MeetingReconciler(
        lifecycle: MeetingLifecycle(store: store),
      );

      final moved = await reconciler.sweep();

      // It stops at processing so post-processing can still run over it.
      expect(store.records['m1']!.status, MeetingStatus.processing);
      expect(moved.single.id, 'm1');
    });

    test('finalizes a stranded recording that captured nothing', () async {
      final store = FakeMeetingStore()
        ..seed(
          const MeetingLifecycleRecord(
            id: 'm1',
            status: MeetingStatus.recording,
          ),
        );
      final reconciler = MeetingReconciler(
        lifecycle: MeetingLifecycle(store: store),
      );

      await reconciler.sweep();

      expect(store.records['m1']!.status, MeetingStatus.done);
    });

    test('finalizes a stranded processing meeting', () async {
      final store = FakeMeetingStore()
        ..seed(
          const MeetingLifecycleRecord(
            id: 'm1',
            status: MeetingStatus.processing,
          ),
        );
      final reconciler = MeetingReconciler(
        lifecycle: MeetingLifecycle(store: store),
      );

      await reconciler.sweep();

      expect(store.records['m1']!.status, MeetingStatus.done);
    });

    test('leaves a meeting whose run is still active', () async {
      final store = FakeMeetingStore()
        ..seed(
          const MeetingLifecycleRecord(
            id: 'm1',
            status: MeetingStatus.processing,
          ),
        );
      final reconciler = MeetingReconciler(
        lifecycle: MeetingLifecycle(store: store),
        isProcessingActive: (id) async => id == 'm1',
      );

      final moved = await reconciler.sweep();

      expect(store.records['m1']!.status, MeetingStatus.processing);
      expect(moved, isEmpty);
    });

    test('sweeps several stranded meetings in one pass', () async {
      final store = FakeMeetingStore()
        ..seed(
          const MeetingLifecycleRecord(
            id: 'a',
            status: MeetingStatus.recording,
          ),
        )
        ..seed(
          const MeetingLifecycleRecord(
            id: 'b',
            status: MeetingStatus.processing,
          ),
        )
        ..seed(
          const MeetingLifecycleRecord(id: 'c', status: MeetingStatus.done),
        );
      final reconciler = MeetingReconciler(
        lifecycle: MeetingLifecycle(store: store),
      );

      await reconciler.sweep();

      expect(store.records['a']!.status, MeetingStatus.done);
      expect(store.records['b']!.status, MeetingStatus.done);
      expect(store.records['c']!.status, MeetingStatus.done);
    });
  });
}
