// The collector contract, compositor, and process collector are derived from
// Control Center's `meeting_signal_collector.dart` and
// `process_meeting_signal_collector.dart`, MIT (c) 2026 Samuel Alev. See NOTICE.

import 'dart:io';

import 'conferencing_apps.dart';
import 'detection.dart';

/// A source of [MeetingSignal]s.
///
/// A host polls one of these on a timer — usually a
/// [CompositeMeetingSignalCollector] — and fuses the result with
/// [resolveMeetingCandidate]. Implementations should be cheap and must not
/// throw; return an empty list on any error.
abstract interface class MeetingSignalCollector {
  /// Returns the signals asserted at [now].
  Future<List<MeetingSignal>> sample(DateTime now);
}

/// Fans one [sample] across several collectors and concatenates their signals.
///
/// A collector that throws contributes nothing rather than failing the sweep.
final class CompositeMeetingSignalCollector implements MeetingSignalCollector {
  /// Creates a compositor over [collectors].
  const CompositeMeetingSignalCollector(this.collectors);

  /// The wrapped collectors.
  final List<MeetingSignalCollector> collectors;

  @override
  Future<List<MeetingSignal>> sample(DateTime now) async {
    final results = await Future.wait(
      collectors.map((collector) async {
        try {
          return await collector.sample(now);
        } on Object {
          return const <MeetingSignal>[];
        }
      }),
    );
    return [for (final result in results) ...result];
  }
}

/// Lists the running processes as raw output lines.
///
/// Injected into [ProcessMeetingSignalCollector] so the collector is testable
/// without spawning anything.
typedef ProcessListRunner = Future<List<String>> Function();

/// Emits a [MeetingSignalKind.conferencingApp] signal when a per-meeting
/// conferencing client is running.
///
/// Cross-platform through `ps -axo comm` on macOS and Linux, `tasklist /fo csv
/// /nh` on Windows. Persistent clients such as Teams, Slack, and Discord are
/// deliberately ignored — see [ConferencingApp.persistent].
final class ProcessMeetingSignalCollector implements MeetingSignalCollector {
  /// Creates a collector, optionally overriding how processes are listed.
  ProcessMeetingSignalCollector({ProcessListRunner? runProcessList})
    : _runProcessList = runProcessList ?? _defaultProcessList;

  final ProcessListRunner _runProcessList;

  @override
  Future<List<MeetingSignal>> sample(DateTime now) async {
    final List<String> lines;
    try {
      lines = await _runProcessList();
    } on Object {
      return const [];
    }
    // One signal per distinct application, even when it spawns helpers.
    final seen = <String>{};
    final signals = <MeetingSignal>[];
    for (final line in lines) {
      final app = matchPerMeetingProcess(line);
      if (app != null && seen.add(app.name)) {
        signals.add(
          MeetingSignal(
            kind: MeetingSignalKind.conferencingApp,
            active: true,
            at: now,
            label: app.name,
          ),
        );
      }
    }
    return signals;
  }

  static Future<List<String>> _defaultProcessList() async {
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', ['/fo', 'csv', '/nh']);
      return _splitLines(result.stdout);
    }
    final result = await Process.run('ps', ['-axo', 'comm']);
    return _splitLines(result.stdout);
  }

  static List<String> _splitLines(Object? stdout) {
    if (stdout is! String) {
      return const [];
    }
    return stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }
}
