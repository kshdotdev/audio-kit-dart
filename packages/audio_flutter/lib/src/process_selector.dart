import 'system_audio.dart';

/// Expands a caller's target apps into every process that actually renders
/// their audio.
///
/// Tapping "Microsoft Teams" or "Google Chrome" by its main process ID
/// captures nothing: Electron and Chromium apps render audio from helper
/// processes (`com.microsoft.teams2.helper.gpu`, `Google Chrome Helper`), and
/// Safari and Firefox render web-call audio in shared engine processes that
/// carry a completely different bundle namespace. A selector turns the target
/// set into the process set to tap.
///
/// This is a pure function over a [FlutterSystemAudio.listProcesses] snapshot,
/// so it is testable without any audio hardware and can be re-run whenever the
/// process list changes.
///
/// ```dart
/// final processes = await FlutterSystemAudio().listProcesses();
/// final targets = const SystemAudioProcessSelector().expand(
///   processes: processes,
///   bundleIds: <String>['com.microsoft.teams2'],
/// );
/// final config = FlutterAudioCaptureConfig(
///   type: AudioCaptureType.systemAudio,
///   format: format,
///   processIds: targets.map((p) => p.processId).toSet().toList(),
///   // Identity outlives the snapshot: pass it so platforms that tap by
///   // bundle ID keep the app after its helpers respawn.
///   bundleIds: const SystemAudioProcessSelector().expandBundleIds(
///     processes: processes,
///     bundleIds: <String>['com.microsoft.teams2'],
///   ),
/// );
/// ```
final class SystemAudioProcessSelector {
  /// Creates a selector, optionally replacing the built-in tables.
  ///
  /// Every table is public and overridable because bundle IDs are the app
  /// ecosystem's business, not this package's: a new Chromium fork or a
  /// renamed Teams build must be expressible without waiting for a release.
  const SystemAudioProcessSelector({
    this.externalMediaBundlePrefixes = browserExternalMediaBundlePrefixes,
    this.familyBundlePrefixes = teamsBundlePrefixes,
    this.familyProcessNamePrefixes = teamsProcessNamePrefixes,
  });

  /// Browsers that render call audio outside their own bundle namespace,
  /// mapped to the bundle-ID prefixes of the processes that do it.
  ///
  /// Safari's media capture runs in shared `com.apple.WebKit.*` XPC services
  /// that any WKWebView app can use, so tapping Safari can momentarily pick up
  /// another WebView app's audio. That is unavoidable with shared services and
  /// is the trade for capturing Safari calls at all. Firefox brokers capture
  /// through `org.mozilla.plugincontainer`.
  ///
  /// Chromium browsers are absent on purpose: their helpers carry the
  /// browser's own bundle prefix, so plain prefix expansion already finds
  /// them.
  static const Map<String, List<String>> browserExternalMediaBundlePrefixes =
      <String, List<String>>{
        'com.apple.Safari': <String>['com.apple.WebKit'],
        'org.mozilla.firefox': <String>['org.mozilla.plugincontainer'],
      };

  /// Browsers known to render meeting audio, in bundle-ID form.
  ///
  /// Informational: a browser is expanded because the caller named it, not
  /// because it appears here. Apps use this to offer a browser picker without
  /// hard-coding the same eight strings again.
  static const List<String> browserBundleIds = <String>[
    'com.google.Chrome',
    'com.microsoft.edgemac',
    'com.brave.Browser',
    'company.thebrowser.Browser',
    'com.vivaldi.Vivaldi',
    'org.chromium.Chromium',
    'org.mozilla.firefox',
    'com.apple.Safari',
  ];

  /// Bundle-ID prefixes of app families whose members ship under several
  /// bundle IDs, any one of which stands for the whole family.
  ///
  /// Teams is the reason this exists: its builds have shipped as
  /// `com.microsoft.teams` and `com.microsoft.teams2`, with helper processes
  /// under both, so a caller who asks for one of them means all of them.
  /// Matching by family prefix is locale-independent, unlike matching the
  /// display name.
  static const List<String> teamsBundlePrefixes = <String>[
    'com.microsoft.teams',
  ];

  /// Lowercased display-name prefixes for the same family, used only when the
  /// caller supplies process names.
  ///
  /// The Core Audio process list carries bundle IDs, not display names, so
  /// this is a safety net for builds whose helpers ship under an unrelated
  /// bundle ID and can only be recognised by name.
  static const List<String> teamsProcessNamePrefixes = <String>[
    'microsoft teams',
  ];

  /// Bundle-ID suffixes Electron and Chromium give their helper processes.
  ///
  /// Finding helpers needs no enumeration — they carry their app's prefix —
  /// but going the other way does: a caller holding a helper's bundle ID or
  /// PID means the app, and tapping the one helper it happens to name would
  /// capture nothing as soon as audio moved to a sibling. See
  /// [isHelperBundleId].
  static const List<String> electronHelperBundleSuffixes = <String>[
    '.helper',
    '.helper.gpu',
    '.helper.renderer',
    '.helper.plugin',
  ];

  /// See [browserExternalMediaBundlePrefixes].
  final Map<String, List<String>> externalMediaBundlePrefixes;

  /// See [teamsBundlePrefixes].
  final List<String> familyBundlePrefixes;

  /// See [teamsProcessNamePrefixes].
  final List<String> familyProcessNamePrefixes;

  /// Returns every process in [processes] whose audio belongs to the requested
  /// targets, in list order and without duplicates.
  ///
  /// Targets are given as any mix of:
  /// - [bundleIds] — exact bundle IDs. Each selects that bundle and its helper
  ///   namespace (`id` and `id.*`), never an unrelated bundle that merely
  ///   starts with the same characters;
  /// - [bundlePrefixes] — raw prefixes for apps whose bundle IDs this package
  ///   does not know. Matched loosely, so `com.acme.Edit` also selects
  ///   `com.acme.Editor`;
  /// - [processIds] — process IDs whose bundle ID is resolved from
  ///   [processes], so a caller holding only a PID gets the same expansion.
  ///
  /// A target that is itself a helper widens to the app that owns it, in
  /// either form.
  ///
  /// [processNames] maps a process ID to its display name and is only needed
  /// for the name-based family rules; the Core Audio process list does not
  /// carry names.
  ///
  /// An empty result means nothing matched. That is a real answer — the target
  /// is not producing audio right now — and callers must not fall back to
  /// tapping the bare target PID, which is what silently captures nothing.
  List<AudioCaptureProcess> expand({
    required List<AudioCaptureProcess> processes,
    Iterable<String> bundleIds = const <String>[],
    Iterable<String> bundlePrefixes = const <String>[],
    Iterable<int> processIds = const <int>[],
    Map<int, String> processNames = const <int, String>{},
  }) {
    final _SelectorTargets targets = _resolveTargets(
      processes: processes,
      bundleIds: bundleIds,
      bundlePrefixes: bundlePrefixes,
      processIds: processIds,
    );

    final Set<int> seen = <int>{};
    return <AudioCaptureProcess>[
      for (final AudioCaptureProcess process in processes)
        if (targets.selects(process, name: processNames[process.processId]) &&
            seen.add(process.processId))
          process,
    ];
  }

  /// Convenience wrapper around [expand] returning the process IDs to hand to
  /// `FlutterAudioCaptureConfig.processIds`.
  List<int> expandProcessIds({
    required List<AudioCaptureProcess> processes,
    Iterable<String> bundleIds = const <String>[],
    Iterable<String> bundlePrefixes = const <String>[],
    Iterable<int> processIds = const <int>[],
    Map<int, String> processNames = const <int, String>{},
  }) => expand(
    processes: processes,
    bundleIds: bundleIds,
    bundlePrefixes: bundlePrefixes,
    processIds: processIds,
    processNames: processNames,
  ).map((AudioCaptureProcess process) => process.processId).toList();

  /// Returns the bundle IDs that stand for the requested targets, to hand to
  /// `FlutterAudioCaptureConfig.bundleIds`.
  ///
  /// Where [expandProcessIds] answers "what is playing this app's audio right
  /// now", this answers "which applications is the caller asking for" — the
  /// answer a platform needs to keep following the app after a helper
  /// respawns or the app itself restarts. It contains, in order and without
  /// case-insensitive duplicates:
  /// - each requested target widened from a helper to the app that owns it,
  ///   plus the known-family bundle IDs that target belongs to, so a family
  ///   member that is not running yet is still named; and
  /// - the bundle ID of every process [expand] currently selects, so a
  ///   platform that resolves bundle IDs to processes sees today's helpers
  ///   without having to know the helper naming rules.
  ///
  /// An empty result means nothing matched and the caller named nothing
  /// resolvable, which is the same real answer [expand] gives.
  List<String> expandBundleIds({
    required List<AudioCaptureProcess> processes,
    Iterable<String> bundleIds = const <String>[],
    Iterable<String> bundlePrefixes = const <String>[],
    Iterable<int> processIds = const <int>[],
    Map<int, String> processNames = const <int, String>{},
  }) {
    final _SelectorTargets targets = _resolveTargets(
      processes: processes,
      bundleIds: bundleIds,
      bundlePrefixes: bundlePrefixes,
      processIds: processIds,
    );

    final Set<String> seen = <String>{};
    final List<String> selected = <String>[];
    for (final String bundleId in <String>[
      ...targets.namedApplications,
      for (final AudioCaptureProcess process in processes)
        if (targets.selects(process, name: processNames[process.processId]))
          process.bundleId,
    ]) {
      if (bundleId.isNotEmpty && seen.add(bundleId.toLowerCase())) {
        selected.add(bundleId);
      }
    }
    return selected;
  }

  /// Whether [bundleId] looks like an Electron or Chromium helper process.
  ///
  /// Presentational only: helpers are tapped because they match their app's
  /// prefix, not because of this.
  static bool isHelperBundleId(String bundleId) {
    final String lowercased = bundleId.toLowerCase();
    return electronHelperBundleSuffixes.any(
      (String suffix) =>
          lowercased.endsWith(suffix) || lowercased.contains('$suffix.'),
    );
  }

  /// Resolves a caller's targets into the matching rules every expansion
  /// shares, so process expansion and bundle-ID expansion can never drift.
  _SelectorTargets _resolveTargets({
    required List<AudioCaptureProcess> processes,
    required Iterable<String> bundleIds,
    required Iterable<String> bundlePrefixes,
    required Iterable<int> processIds,
  }) {
    final List<String> namedApplications = <String>[];
    final Set<String> bundleNamespaces = <String>{};
    final Set<String> loosePrefixes = <String>{...bundlePrefixes};
    for (final String bundleId in <String>[
      ...bundleIds,
      // A PID-only caller is a bundle-ID caller once the snapshot resolves it.
      for (final int processId in processIds)
        ...processes
            .where(
              (AudioCaptureProcess process) =>
                  process.processId == processId && process.bundleId.isNotEmpty,
            )
            .map((AudioCaptureProcess process) => process.bundleId),
    ]) {
      // A helper stands for its app, so the app's whole helper namespace and
      // the app's own external media processes come along.
      final String target = _parentBundleId(bundleId) ?? bundleId;
      bundleNamespaces.add(target);
      namedApplications.add(target);
      bundleNamespaces.addAll(
        externalMediaBundlePrefixes[target] ?? const <String>[],
      );
      // Any member of a known family pulls in the whole family: builds that
      // ship as `com.microsoft.teams` and `com.microsoft.teams2` are one app
      // to the user, and a helper can carry either.
      final Iterable<String> families = familyBundlePrefixes.where(
        (String prefix) => _startsWith(bundleId, prefix),
      );
      loosePrefixes.addAll(families);
      // A family prefix is itself a shipped bundle ID, unlike the raw
      // prefixes a caller passes, so it can name an application on its own.
      namedApplications.addAll(families);
    }
    bundleNamespaces.removeWhere((String prefix) => prefix.isEmpty);
    loosePrefixes.removeWhere((String prefix) => prefix.isEmpty);

    return _SelectorTargets(
      namedApplications: namedApplications,
      bundleNamespaces: bundleNamespaces,
      loosePrefixes: loosePrefixes,
      // The name rules exist to catch helpers of an already-selected family
      // that ship under an unrelated bundle ID; they never introduce a new
      // family.
      familySelected: familyBundlePrefixes.any(loosePrefixes.contains),
      familyProcessNamePrefixes: familyProcessNamePrefixes,
    );
  }

  /// The main process, or one of its helpers, and nothing that merely starts
  /// with the same characters: `com.google.Chrome` selects
  /// `com.google.Chrome.helper` but never `com.google.ChromeRemoteDesktop`.
  static bool _matchesNamespace(String bundleId, String prefix) {
    if (bundleId.isEmpty || prefix.isEmpty) {
      return false;
    }
    final String candidate = bundleId.toLowerCase();
    final String lowercased = prefix.toLowerCase();
    return candidate == lowercased || candidate.startsWith('$lowercased.');
  }

  /// The app a helper bundle ID belongs to, or null when [bundleId] is not a
  /// helper.
  ///
  /// Trimming stops at three components: `com.acme.helper` is far more likely
  /// to be an app called "helper" than a helper of the whole `com.acme`
  /// namespace, and widening it would tap every app that vendor ships.
  static String? _parentBundleId(String bundleId) {
    final String lowercased = bundleId.toLowerCase();
    String? longest;
    for (final String suffix in electronHelperBundleSuffixes) {
      if (!lowercased.endsWith(suffix)) {
        continue;
      }
      if (longest == null || suffix.length > longest.length) {
        longest = suffix;
      }
    }
    if (longest == null) {
      return null;
    }
    final String parent = bundleId.substring(
      0,
      bundleId.length - longest.length,
    );
    return parent.split('.').length >= 3 ? parent : null;
  }

  static bool _startsWith(String bundleId, String prefix) =>
      bundleId.isNotEmpty &&
      prefix.isNotEmpty &&
      bundleId.toLowerCase().startsWith(prefix.toLowerCase());
}

/// One caller's targets, resolved once into the rules both expansions read.
final class _SelectorTargets {
  const _SelectorTargets({
    required this.namedApplications,
    required this.bundleNamespaces,
    required this.loosePrefixes,
    required this.familySelected,
    required this.familyProcessNamePrefixes,
  });

  /// Applications the caller named, in request order and helper-widened.
  final List<String> namedApplications;

  final Set<String> bundleNamespaces;
  final Set<String> loosePrefixes;
  final bool familySelected;
  final List<String> familyProcessNamePrefixes;

  bool selects(AudioCaptureProcess process, {required String? name}) {
    if (bundleNamespaces.any(
      (String prefix) => SystemAudioProcessSelector._matchesNamespace(
        process.bundleId,
        prefix,
      ),
    )) {
      return true;
    }
    if (loosePrefixes.any(
      (String prefix) =>
          SystemAudioProcessSelector._startsWith(process.bundleId, prefix),
    )) {
      return true;
    }
    if (!familySelected || name == null || process.bundleId.isEmpty) {
      return false;
    }
    // Name matching only ever adds processes to an already-selected family,
    // and only ones the audio server can attribute to a bundle at all.
    final String lowercased = name.toLowerCase();
    return familyProcessNamePrefixes.any(
      (String prefix) => lowercased.startsWith(prefix),
    );
  }
}
