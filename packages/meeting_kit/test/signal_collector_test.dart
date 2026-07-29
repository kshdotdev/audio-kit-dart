// Collector behaviour ported from Control Center's
// process_meeting_signal_collector.dart, MIT (c) 2026 Samuel Alev. See NOTICE.

import 'package:meeting_kit/meeting_kit.dart';
import 'package:test/test.dart';

final class _StubCollector implements MeetingSignalCollector {
  _StubCollector(this.signals, {this.throws = false});

  final List<MeetingSignal> signals;
  final bool throws;

  @override
  Future<List<MeetingSignal>> sample(DateTime now) async {
    if (throws) {
      throw StateError('collector exploded');
    }
    return signals;
  }
}

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);

  group('matchPerMeetingProcess', () {
    test('matches a per-meeting client', () {
      expect(matchPerMeetingProcess('/Applications/zoom.us')?.name, 'Zoom');
      expect(matchPerMeetingProcess('WebexHost.exe')?.name, 'Webex');
    });

    test('ignores persistent clients', () {
      expect(matchPerMeetingProcess('/Applications/Slack.app'), isNull);
      expect(matchPerMeetingProcess('Microsoft Teams'), isNull);
      expect(matchPerMeetingProcess('Discord'), isNull);
    });

    test('returns null for unrelated processes', () {
      expect(matchPerMeetingProcess('/usr/bin/ssh'), isNull);
    });
  });

  group('matchMeetingUrl', () {
    test('matches a meeting URL, including persistent clients', () {
      expect(
        matchMeetingUrl('https://meet.google.com/abc')?.name,
        'Google Meet',
      );
      expect(
        matchMeetingUrl('https://teams.microsoft.com/l/meetup')?.name,
        'Microsoft Teams',
      );
    });

    test('returns null for an unrelated URL', () {
      expect(matchMeetingUrl('https://example.com'), isNull);
    });
  });

  group('ProcessMeetingSignalCollector', () {
    test('emits one signal per distinct application', () async {
      final collector = ProcessMeetingSignalCollector(
        runProcessList: () async => [
          '/Applications/zoom.us/Contents/MacOS/zoom.us',
          '/Applications/zoom.us/Contents/MacOS/caphost',
          '/usr/bin/ssh',
        ],
      );

      final signals = await collector.sample(now);

      expect(signals, hasLength(1));
      expect(signals.single.kind, MeetingSignalKind.conferencingApp);
      expect(signals.single.label, 'Zoom');
      expect(signals.single.active, isTrue);
      expect(signals.single.at, now);
    });

    test('emits nothing when no client is running', () async {
      final collector = ProcessMeetingSignalCollector(
        runProcessList: () async => ['/usr/bin/ssh', 'Finder'],
      );

      expect(await collector.sample(now), isEmpty);
    });

    test('swallows a failing process listing', () async {
      final collector = ProcessMeetingSignalCollector(
        runProcessList: () async => throw StateError('no ps here'),
      );

      expect(await collector.sample(now), isEmpty);
    });

    test('separates distinct applications', () async {
      final collector = ProcessMeetingSignalCollector(
        runProcessList: () async => ['zoom.us', 'WebexHost'],
      );

      final labels = (await collector.sample(now)).map((s) => s.label);
      expect(labels, containsAll(['Zoom', 'Webex']));
    });
  });

  group('CompositeMeetingSignalCollector', () {
    test('concatenates every collector result', () async {
      final composite = CompositeMeetingSignalCollector([
        _StubCollector([
          MeetingSignal(
            kind: MeetingSignalKind.conferencingApp,
            active: true,
            at: now,
          ),
        ]),
        _StubCollector([
          MeetingSignal(
            kind: MeetingSignalKind.calendarEvent,
            active: true,
            at: now,
          ),
        ]),
      ]);

      expect(await composite.sample(now), hasLength(2));
    });

    test('a throwing collector contributes nothing', () async {
      final composite = CompositeMeetingSignalCollector([
        _StubCollector(const [], throws: true),
        _StubCollector([
          MeetingSignal(kind: MeetingSignalKind.camera, active: true, at: now),
        ]),
      ]);

      final signals = await composite.sample(now);

      expect(signals, hasLength(1));
      expect(signals.single.kind, MeetingSignalKind.camera);
    });

    test('is empty with no collectors', () async {
      expect(
        await const CompositeMeetingSignalCollector([]).sample(now),
        isEmpty,
      );
    });
  });
}
