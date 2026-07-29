// The conferencing catalog and its matchers are derived from Control Center's
// `conferencing_apps.dart`, MIT (c) 2026 Samuel Alev. See NOTICE.

/// One conferencing product and how to recognize it.
final class ConferencingApp {
  /// Creates a catalog entry.
  const ConferencingApp({
    required this.name,
    this.processNames = const [],
    this.urlHosts = const [],
    this.persistent = false,
  });

  /// Display name, used as the signal label.
  final String name;

  /// Lower-case substrings matched against a running process or executable
  /// name.
  final List<String> processNames;

  /// Host substrings identifying a meeting URL for this product.
  final List<String> urlHosts;

  /// Whether the desktop client typically runs in the background all day.
  ///
  /// A running process is *not* evidence of a live meeting for these, so
  /// [matchPerMeetingProcess] skips them; they need a frontmost-window, camera,
  /// or audio signal to be detected reliably.
  final bool persistent;
}

/// The known conferencing applications.
///
/// Per-meeting clients are launched for a call and quit afterward, so their
/// mere presence is a usable signal. Persistent clients are flagged so the
/// process collector ignores them.
const List<ConferencingApp> conferencingApps = [
  ConferencingApp(
    name: 'Zoom',
    processNames: ['zoom.us', 'zoom', 'caphost', 'aomhost'],
    urlHosts: ['zoom.us'],
  ),
  ConferencingApp(name: 'Google Meet', urlHosts: ['meet.google.com']),
  ConferencingApp(
    name: 'Microsoft Teams',
    processNames: ['teams', 'msteams', 'ms-teams'],
    urlHosts: ['teams.microsoft.com', 'teams.live.com'],
    persistent: true,
  ),
  ConferencingApp(
    name: 'Webex',
    processNames: ['webex', 'ciscowebex', 'webexmta', 'webexhost'],
    urlHosts: ['webex.com'],
  ),
  ConferencingApp(
    name: 'Slack',
    processNames: ['slack'],
    urlHosts: ['app.slack.com'],
    persistent: true,
  ),
  ConferencingApp(
    name: 'Discord',
    processNames: ['discord'],
    urlHosts: ['discord.com/channels'],
    persistent: true,
  ),
  ConferencingApp(
    name: 'GoTo Meeting',
    processNames: ['gotomeeting', 'g2mstart', 'g2mcomm'],
    urlHosts: ['gotomeeting.com'],
  ),
  ConferencingApp(
    name: 'BlueJeans',
    processNames: ['bluejeans'],
    urlHosts: ['bluejeans.com'],
  ),
  ConferencingApp(
    name: 'Around',
    processNames: ['around'],
    urlHosts: ['around.co'],
  ),
];

/// Returns the per-meeting application whose process name matches
/// [processLine], or null.
///
/// Matching is a case-insensitive substring test. Persistent applications are
/// deliberately excluded — see [ConferencingApp.persistent].
ConferencingApp? matchPerMeetingProcess(String processLine) {
  final haystack = processLine.toLowerCase();
  for (final app in conferencingApps) {
    if (app.persistent) {
      continue;
    }
    for (final needle in app.processNames) {
      if (haystack.contains(needle)) {
        return app;
      }
    }
  }
  return null;
}

/// Returns the conferencing application whose URL host matches [url], or null.
///
/// Unlike [matchPerMeetingProcess] this includes persistent applications: a
/// meeting URL *is* evidence even for an always-running client.
ConferencingApp? matchMeetingUrl(String url) {
  final haystack = url.toLowerCase();
  for (final app in conferencingApps) {
    for (final host in app.urlHosts) {
      if (haystack.contains(host)) {
        return app;
      }
    }
  }
  return null;
}
