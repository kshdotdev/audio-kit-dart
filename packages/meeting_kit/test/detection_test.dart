// Ported from Control Center's meeting_detection_test.dart,
// MIT (c) 2026 Samuel Alev. See NOTICE.

import 'package:meeting_kit/meeting_kit.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);

  MeetingSignal signal(
    MeetingSignalKind kind, {
    bool active = true,
    int agoSeconds = 0,
    String? label,
  }) => MeetingSignal(
    kind: kind,
    active: active,
    at: t0.subtract(Duration(seconds: agoSeconds)),
    label: label,
  );

  group('resolveMeetingCandidate', () {
    test('a single strong signal is enough', () {
      final candidate = resolveMeetingCandidate([
        signal(MeetingSignalKind.conferencingApp, label: 'Zoom'),
      ], now: t0);

      expect(candidate, isNotNull);
      expect(candidate!.primary, MeetingSignalKind.conferencingApp);
      expect(candidate.label, 'Zoom');
      expect(candidate.confidence, greaterThanOrEqualTo(0.6));
    });

    test('weak signals need corroboration to cross the threshold', () {
      // Camera 0.4 plus one bonus of 0.15 is 0.55, still under 0.6.
      expect(
        resolveMeetingCandidate([
          signal(MeetingSignalKind.camera),
          signal(MeetingSignalKind.systemAudioActive),
        ], now: t0),
        isNull,
      );

      // A third weak signal pushes it over: 0.4 plus 0.30 is 0.70.
      final candidate = resolveMeetingCandidate([
        signal(MeetingSignalKind.camera),
        signal(MeetingSignalKind.systemAudioActive),
        signal(MeetingSignalKind.microphoneInUse),
      ], now: t0);

      expect(candidate, isNotNull);
      expect(candidate!.confidence, greaterThanOrEqualTo(0.6));
    });

    test('a lone weak signal stays below the threshold', () {
      expect(
        resolveMeetingCandidate([signal(MeetingSignalKind.camera)], now: t0),
        isNull,
      );
    });

    test('active recording alone is sufficient', () {
      final candidate = resolveMeetingCandidate([
        signal(MeetingSignalKind.activeRecording),
      ], now: t0);

      expect(candidate, isNotNull);
      expect(candidate!.primary, MeetingSignalKind.activeRecording);
    });

    test('stale signals are ignored', () {
      expect(
        resolveMeetingCandidate([
          signal(MeetingSignalKind.conferencingApp, agoSeconds: 60),
        ], now: t0),
        isNull,
      );
    });

    test('future-stamped signals are ignored', () {
      expect(
        resolveMeetingCandidate([
          signal(MeetingSignalKind.conferencingApp, agoSeconds: -5),
        ], now: t0),
        isNull,
      );
    });

    test('inactive signals do not count', () {
      expect(
        resolveMeetingCandidate([
          signal(MeetingSignalKind.conferencingApp, active: false),
        ], now: t0),
        isNull,
      );
    });

    test('confidence is clamped to one', () {
      final candidate = resolveMeetingCandidate([
        signal(MeetingSignalKind.activeRecording),
        signal(MeetingSignalKind.conferencingApp),
        signal(MeetingSignalKind.browserMeeting),
        signal(MeetingSignalKind.camera),
        signal(MeetingSignalKind.microphoneInUse),
      ], now: t0);

      expect(candidate!.confidence, 1.0);
    });

    test('the newest observation per kind wins', () {
      final candidate = resolveMeetingCandidate([
        signal(MeetingSignalKind.conferencingApp, agoSeconds: 10, label: 'old'),
        signal(MeetingSignalKind.conferencingApp, label: 'new'),
      ], now: t0);

      expect(candidate!.label, 'new');
    });

    test('custom weights override the defaults', () {
      const policy = MeetingDetectionPolicy(
        weights: {MeetingSignalKind.camera: 0.95},
      );

      final candidate = resolveMeetingCandidate(
        [signal(MeetingSignalKind.camera)],
        now: t0,
        policy: policy,
      );

      expect(candidate, isNotNull);
      expect(candidate!.primary, MeetingSignalKind.camera);
    });
  });

  group('MeetingDetectionStateMachine', () {
    MeetingCandidate candidate({String? label, int sinceSeconds = 0}) =>
        MeetingCandidate(
          confidence: 0.9,
          primary: MeetingSignalKind.conferencingApp,
          label: label,
          since: t0.subtract(Duration(seconds: sinceSeconds)),
        );

    test('debounces and prompts only after the presence window', () {
      final machine = MeetingDetectionStateMachine(
        policy: const MeetingDetectionPolicy(minPresence: Duration(seconds: 8)),
      );

      expect(
        machine.update(
          candidate: candidate(label: 'a'),
          now: t0,
        ),
        MeetingDetectionAction.none,
      );
      expect(machine.state, MeetingDetectionState.watching);

      final later = t0.add(const Duration(seconds: 9));
      expect(
        machine.update(
          candidate: candidate(label: 'a', sinceSeconds: 9),
          now: later,
        ),
        MeetingDetectionAction.showPrompt,
      );
      expect(machine.state, MeetingDetectionState.prompting);

      expect(
        machine.update(
          candidate: candidate(label: 'a', sinceSeconds: 10),
          now: later,
        ),
        MeetingDetectionAction.none,
      );
    });

    test('hides the prompt when the candidate vanishes', () {
      final machine = MeetingDetectionStateMachine(
        policy: const MeetingDetectionPolicy(minPresence: Duration.zero),
      );

      expect(
        machine.update(
          candidate: candidate(label: 'a'),
          now: t0,
        ),
        MeetingDetectionAction.showPrompt,
      );
      expect(
        machine.update(
          candidate: null,
          now: t0.add(const Duration(seconds: 1)),
        ),
        MeetingDetectionAction.hidePrompt,
      );
      expect(machine.state, MeetingDetectionState.idle);
    });

    test('a dismissed label is suppressed until it clears', () {
      final machine = MeetingDetectionStateMachine(
        policy: const MeetingDetectionPolicy(minPresence: Duration.zero),
      );

      machine.update(
        candidate: candidate(label: 'a'),
        now: t0,
      );
      machine.dismiss('a');

      expect(
        machine.update(
          candidate: candidate(label: 'a'),
          now: t0.add(const Duration(seconds: 5)),
        ),
        MeetingDetectionAction.none,
      );

      expect(
        machine.update(
          candidate: candidate(label: 'b'),
          now: t0.add(const Duration(seconds: 6)),
        ),
        MeetingDetectionAction.showPrompt,
      );
    });

    test('suggests auto-stop after a sustained gap while recording', () {
      final machine = MeetingDetectionStateMachine(
        policy: const MeetingDetectionPolicy(
          minPresence: Duration.zero,
          autoStopAfter: Duration(seconds: 90),
        ),
      );

      machine.update(
        candidate: candidate(label: 'a'),
        now: t0,
      );
      machine.accept();
      expect(machine.state, MeetingDetectionState.recording);

      expect(
        machine.update(
          candidate: null,
          now: t0.add(const Duration(seconds: 30)),
        ),
        MeetingDetectionAction.none,
      );
      expect(
        machine.update(
          candidate: null,
          now: t0.add(const Duration(seconds: 95)),
        ),
        MeetingDetectionAction.suggestAutoStop,
      );
    });

    test('ongoing activity holds off auto-stop until speech stops', () {
      final machine = MeetingDetectionStateMachine(
        policy: const MeetingDetectionPolicy(
          minPresence: Duration.zero,
          autoStopAfter: Duration(seconds: 90),
        ),
      );

      machine.update(
        candidate: candidate(label: 'a'),
        now: t0,
      );
      machine.accept();

      var now = t0;
      MeetingCandidate recording() => MeetingCandidate(
        confidence: 0.9,
        primary: MeetingSignalKind.activeRecording,
        since: now,
      );

      // Someone keeps talking for five minutes, well past the auto-stop window.
      for (var i = 0; i < 10; i++) {
        now = now.add(const Duration(seconds: 30));
        expect(
          machine.update(candidate: recording(), now: now),
          MeetingDetectionAction.none,
        );
      }

      // Only once speech stops does the gap open, and it must run its course.
      expect(
        machine.update(
          candidate: null,
          now: now.add(const Duration(seconds: 30)),
        ),
        MeetingDetectionAction.none,
      );
      expect(
        machine.update(
          candidate: null,
          now: now.add(const Duration(seconds: 95)),
        ),
        MeetingDetectionAction.suggestAutoStop,
      );
    });

    test('stopped returns the machine to idle detection', () {
      final machine = MeetingDetectionStateMachine(
        policy: const MeetingDetectionPolicy(minPresence: Duration.zero),
      );

      machine.update(
        candidate: candidate(label: 'a'),
        now: t0,
      );
      machine.accept();
      machine.stopped();

      expect(machine.state, MeetingDetectionState.idle);
      expect(
        machine.update(
          candidate: candidate(label: 'a'),
          now: t0,
        ),
        MeetingDetectionAction.showPrompt,
      );
    });
  });
}
