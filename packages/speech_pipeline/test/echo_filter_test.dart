import 'dart:async';

import 'package:speech_pipeline/speech_pipeline.dart';
import 'package:test/test.dart';

// Cases ported from Control Center's `meeting_echo_filter_test.dart`
// (MIT © 2026 Samuel Alev), adapted to the injected hold scheduler. See NOTICE.

/// Collects scheduled holds so tests can fire them on demand instead of
/// waiting real time.
final class _ManualScheduler {
  final List<_ScheduledHold> holds = <_ScheduledHold>[];

  Timer schedule(Duration delay, void Function() callback) {
    final hold = _ScheduledHold(delay, callback);
    holds.add(hold);
    return hold;
  }

  /// Fires every live hold, longest delay last.
  void fireAll() {
    final live = holds.where((hold) => hold.isActive).toList()
      ..sort((a, b) => a.delay.compareTo(b.delay));
    for (final hold in live) {
      hold.fire();
    }
  }

  Duration? get lastDelay => holds.isEmpty ? null : holds.last.delay;
}

final class _ScheduledHold implements Timer {
  _ScheduledHold(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _cancelled = false;
  bool _fired = false;

  @override
  bool get isActive => !_cancelled && !_fired;

  @override
  int get tick => 0;

  @override
  void cancel() => _cancelled = true;

  void fire() {
    if (!isActive) {
      return;
    }
    _fired = true;
    _callback();
  }
}

TranscriptSegment _segment(String text, {String trackId = 'me'}) =>
    TranscriptSegment(
      trackId: trackId,
      text: text,
      start: Duration.zero,
      end: const Duration(seconds: 2),
    );

EchoCandidate _near(String text, int emitMs) => EchoCandidate(
  role: EchoTrackRole.near,
  segment: _segment(text),
  emitTime: Duration(milliseconds: emitMs),
);

EchoCandidate _far(String text, int emitMs) => EchoCandidate(
  role: EchoTrackRole.far,
  segment: _segment(text, trackId: 'them'),
  emitTime: Duration(milliseconds: emitMs),
);

void main() {
  group('echo token helpers', () {
    test('normalizes case and folds out punctuation', () {
      expect(
        echoTokens('Hey, THERE! Ship it.'),
        orderedEquals(<String>['hey', 'there', 'ship', 'it']),
      );
    });

    test('scores containment, not Jaccard', () {
      final fragment = <String>{'ship', 'the', 'release'};
      final full = <String>{
        'okay',
        'so',
        'lets',
        'ship',
        'the',
        'release',
        'today',
      };
      // A clean subset scores 1.0; Jaccard would score this about 0.43.
      expect(echoSimilarity(fragment, full), 1.0);
      expect(isEchoMatch(fragment, full), isTrue);
    });

    test('scores disjoint sets zero', () {
      expect(echoSimilarity(<String>{'a'}, <String>{'b'}), 0);
      expect(echoSimilarity(<String>{}, <String>{'b'}), 0);
    });
  });

  group('TranscriptEchoFilter', () {
    test('rejects an activeHold shorter than the match window', () {
      expect(
        () => TranscriptEchoFilter(
          activeHold: const Duration(seconds: 1),
          matchWindow: const Duration(seconds: 7),
        ),
        throwsArgumentError,
      );
    });

    test('commits far windows immediately and never holds them', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);
      final accepted = <String>[];
      filter.accepted.listen((segment) => accepted.add(segment.text));

      filter.add(_far('ship the release today', 1000));
      await pumpEventQueue();

      expect(accepted, <String>['ship the release today']);
      expect(scheduler.holds, isEmpty);
      await filter.dispose();
    });

    test('drops a near window that echoes a buffered far window', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);
      final accepted = <String>[];
      filter.accepted.listen((segment) => accepted.add(segment.text));

      filter
        ..add(_far('okay so lets ship the release today', 1000))
        ..add(_near('ship the release', 1400));
      scheduler.fireAll();
      await pumpEventQueue();

      expect(accepted, <String>['okay so lets ship the release today']);
      expect(filter.pendingCount, 0);
      await filter.dispose();
    });

    test('cancels a held near window when its far source arrives', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);
      final accepted = <String>[];
      filter.accepted.listen((segment) => accepted.add(segment.text));

      // Far side is playing, so the near window is held rather than committed.
      filter
        ..noteFarActivity(const Duration(milliseconds: 900))
        ..add(_near('ship the release', 1000));
      expect(filter.pendingCount, 1);

      // The authoritative far window arrives late and cancels the hold.
      filter.add(_far('okay so lets ship the release today', 3000));
      scheduler.fireAll();
      await pumpEventQueue();

      expect(accepted, <String>['okay so lets ship the release today']);
      await filter.dispose();
    });

    test('commits a held near window when no far source claims it', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);
      final accepted = <String>[];
      filter.accepted.listen((segment) => accepted.add(segment.text));

      filter
        ..noteFarActivity(const Duration(milliseconds: 900))
        ..add(_near('what about the migration order', 1000));
      scheduler.fireAll();
      await pumpEventQueue();

      expect(accepted, <String>['what about the migration order']);
      await filter.dispose();
    });

    test('holds briefly when the far side has been quiet', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);

      filter.add(_near('starting the deploy now', 1000));

      expect(scheduler.lastDelay, filter.idleHold);
      await filter.dispose();
    });

    test('holds long when the far side played recently', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);

      filter
        ..noteFarActivity(const Duration(milliseconds: 900))
        ..add(_near('starting the deploy now', 1000));

      expect(scheduler.lastDelay, filter.activeHold);
      await filter.dispose();
    });

    test('never matches windows shorter than minTokens', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);
      final accepted = <String>[];
      filter.accepted.listen((segment) => accepted.add(segment.text));

      // A backchannel must survive even though it is contained in the far text.
      filter
        ..add(_far('okay', 1000))
        ..add(_near('okay', 1200));
      scheduler.fireAll();
      await pumpEventQueue();

      expect(accepted, <String>['okay', 'okay']);
      await filter.dispose();
    });

    test('does not match outside the emit-time band', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);
      final accepted = <String>[];
      filter.accepted.listen((segment) => accepted.add(segment.text));

      filter
        ..add(_far('ship the release today', 1000))
        // Far outside matchWindow, though still inside the retention buffer.
        ..add(_near('ship the release today', 10000));
      scheduler.fireAll();
      await pumpEventQueue();

      expect(accepted, hasLength(2));
      await filter.dispose();
    });

    test('drain commits held windows so the tail is not lost', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);
      final accepted = <String>[];
      filter.accepted.listen((segment) => accepted.add(segment.text));

      filter
        ..noteFarActivity(const Duration(milliseconds: 900))
        ..add(_near('one last thing before we stop', 1000));
      expect(filter.pendingCount, 1);

      filter.drain();
      await pumpEventQueue();

      expect(accepted, <String>['one last thing before we stop']);
      expect(filter.pendingCount, 0);
      await filter.dispose();
    });

    test('dispose discards held windows without committing', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);
      final accepted = <String>[];
      filter.accepted.listen((segment) => accepted.add(segment.text));

      filter
        ..noteFarActivity(const Duration(milliseconds: 900))
        ..add(_near('dropped on teardown', 1000));
      await filter.dispose();
      await pumpEventQueue();

      expect(accepted, isEmpty);
      expect(scheduler.holds.single.isActive, isFalse);
    });

    test('ignores candidates after dispose', () async {
      final scheduler = _ManualScheduler();
      final filter = TranscriptEchoFilter(scheduler: scheduler.schedule);
      await filter.dispose();

      filter
        ..noteFarActivity(const Duration(milliseconds: 100))
        ..add(_far('late arrival', 2000));

      expect(filter.pendingCount, 0);
    });
  });
}
