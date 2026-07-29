import 'package:audio_flutter/audio_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Translated from the Swift oracle's `runTeamsIdentificationTests`
/// (ectos Tests/EctosTests/TestRunner.swift) and the tap-expansion rules in
/// `RecordingManager.collectAppProcessObjectIDs`.
///
/// The Swift suite answers "is this the main Teams app", so it *rejects*
/// helpers; tap expansion asks the opposite question and must *include* them.
/// The identifiers are the load-bearing part and are reused verbatim.
void main() {
  const AudioCaptureProcess finder = AudioCaptureProcess(
    processId: 1,
    bundleId: 'com.apple.finder',
    isProducingAudio: false,
  );

  test('Chrome expands to its helper processes', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      finder,
      AudioCaptureProcess(
        processId: 10,
        bundleId: 'com.google.Chrome',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 11,
        bundleId: 'com.google.Chrome.helper',
        isProducingAudio: true,
      ),
      AudioCaptureProcess(
        processId: 12,
        bundleId: 'com.google.Chrome.helper.gpu',
        isProducingAudio: false,
      ),
      // Same first characters, different app: never tapped.
      AudioCaptureProcess(
        processId: 13,
        bundleId: 'com.google.ChromeRemoteDesktop',
        isProducingAudio: true,
      ),
    ];

    expect(
      const SystemAudioProcessSelector().expandProcessIds(
        processes: processes,
        bundleIds: <String>['com.google.Chrome'],
      ),
      <int>[10, 11, 12],
    );
  });

  test('a helper PID expands back to the whole app', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      AudioCaptureProcess(
        processId: 20,
        bundleId: 'com.brave.Browser',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 21,
        bundleId: 'com.brave.Browser.helper.renderer',
        isProducingAudio: true,
      ),
    ];

    expect(
      const SystemAudioProcessSelector().expandProcessIds(
        processes: processes,
        processIds: <int>[21],
      ),
      <int>[20, 21],
    );
  });

  test('Teams is selected by family prefix across build generations', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      finder,
      AudioCaptureProcess(
        processId: 30,
        bundleId: 'com.microsoft.teams',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 31,
        bundleId: 'com.microsoft.teams2',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 32,
        bundleId: 'com.microsoft.teams2.helper',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 33,
        bundleId: 'com.microsoft.teams2.helper.gpu',
        isProducingAudio: true,
      ),
      AudioCaptureProcess(
        processId: 34,
        bundleId: 'com.microsoft.Outlook',
        isProducingAudio: true,
      ),
    ];

    // Asking for the new build collects the classic build and every helper —
    // the Swift scan keyed on `bundle.hasPrefix("com.microsoft.teams")`.
    expect(
      const SystemAudioProcessSelector().expandProcessIds(
        processes: processes,
        bundleIds: <String>['com.microsoft.teams2'],
      ),
      <int>[30, 31, 32, 33],
    );
  });

  test('Teams helpers under an unrelated bundle ID are found by name', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      AudioCaptureProcess(
        processId: 40,
        bundleId: 'com.microsoft.teams2',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 41,
        bundleId: 'com.microsoft.msteams.helper',
        isProducingAudio: true,
      ),
      AudioCaptureProcess(
        processId: 42,
        bundleId: 'us.zoom.xos',
        isProducingAudio: true,
      ),
      // Localized names from the Swift suite. A nameless process with no
      // bundle ID is unattributable and stays out.
      AudioCaptureProcess(processId: 43, bundleId: '', isProducingAudio: true),
    ];

    expect(
      const SystemAudioProcessSelector().expandProcessIds(
        processes: processes,
        bundleIds: <String>['com.microsoft.teams2'],
        processNames: const <int, String>{
          40: 'Microsoft Teams (work or school)',
          41: 'Microsoft Teams Helper (GPU)',
          42: 'zoom.us',
          43: 'Microsoft Teams 团队',
        },
      ),
      <int>[40, 41],
    );
  });

  test('Safari collects the shared WebKit media processes', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      finder,
      AudioCaptureProcess(
        processId: 50,
        bundleId: 'com.apple.Safari',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 51,
        bundleId: 'com.apple.WebKit.GPU',
        isProducingAudio: true,
      ),
      AudioCaptureProcess(
        processId: 52,
        bundleId: 'com.apple.WebKit.WebContent',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 53,
        bundleId: 'com.apple.Music',
        isProducingAudio: true,
      ),
    ];

    expect(
      const SystemAudioProcessSelector().expandProcessIds(
        processes: processes,
        bundleIds: <String>['com.apple.Safari'],
      ),
      <int>[50, 51, 52],
    );
  });

  test('Firefox collects plugin-container, Chrome does not', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      AudioCaptureProcess(
        processId: 60,
        bundleId: 'org.mozilla.firefox',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 61,
        bundleId: 'org.mozilla.plugincontainer',
        isProducingAudio: true,
      ),
      AudioCaptureProcess(
        processId: 62,
        bundleId: 'com.google.Chrome',
        isProducingAudio: false,
      ),
    ];
    const SystemAudioProcessSelector selector = SystemAudioProcessSelector();

    expect(
      selector.expandProcessIds(
        processes: processes,
        bundleIds: <String>['org.mozilla.firefox'],
      ),
      <int>[60, 61],
    );
    expect(
      selector.expandProcessIds(
        processes: processes,
        bundleIds: <String>['com.google.Chrome'],
      ),
      <int>[62],
    );
  });

  test('a target that is not running selects nothing', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[finder];

    expect(
      const SystemAudioProcessSelector().expand(
        processes: processes,
        bundleIds: <String>['com.microsoft.teams2'],
        processIds: <int>[999],
        processNames: const <int, String>{999: 'Microsoft Teams'},
      ),
      isEmpty,
    );
  });

  test('unknown apps pass through by bundle ID and by raw prefix', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      finder,
      AudioCaptureProcess(
        processId: 70,
        bundleId: 'com.acme.Studio',
        isProducingAudio: true,
      ),
      AudioCaptureProcess(
        processId: 71,
        bundleId: 'com.acme.Studio.helper',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 72,
        bundleId: 'com.acme.StudioAssistant',
        isProducingAudio: false,
      ),
    ];
    const SystemAudioProcessSelector selector = SystemAudioProcessSelector();

    // An exact bundle ID keeps to its own namespace...
    expect(
      selector.expandProcessIds(
        processes: processes,
        bundleIds: <String>['com.acme.Studio'],
      ),
      <int>[70, 71],
    );
    // ...while a raw prefix is the caller taking responsibility for the width.
    expect(
      selector.expandProcessIds(
        processes: processes,
        bundlePrefixes: <String>['com.acme.Studio'],
      ),
      <int>[70, 71, 72],
    );
  });

  test('overlapping targets yield each process once, in list order', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      AudioCaptureProcess(
        processId: 80,
        bundleId: 'com.apple.Safari',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 81,
        bundleId: 'com.apple.WebKit.GPU',
        isProducingAudio: true,
      ),
    ];

    expect(
      const SystemAudioProcessSelector().expandProcessIds(
        processes: processes,
        bundleIds: <String>['com.apple.Safari', 'com.apple.WebKit.GPU'],
        bundlePrefixes: <String>['com.apple.WebKit'],
        processIds: <int>[80],
      ),
      <int>[80, 81],
    );
  });

  test('tables are overridable so apps can extend the rules', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      AudioCaptureProcess(
        processId: 90,
        bundleId: 'com.acme.Meet',
        isProducingAudio: false,
      ),
      AudioCaptureProcess(
        processId: 91,
        bundleId: 'com.acme.media-engine',
        isProducingAudio: true,
      ),
    ];

    expect(
      const SystemAudioProcessSelector(
        externalMediaBundlePrefixes: <String, List<String>>{
          'com.acme.Meet': <String>['com.acme.media-engine'],
        },
      ).expandProcessIds(
        processes: processes,
        bundleIds: <String>['com.acme.Meet'],
      ),
      <int>[90, 91],
    );
  });

  test('an app named "helper" is not widened to its whole vendor', () {
    const List<AudioCaptureProcess> processes = <AudioCaptureProcess>[
      AudioCaptureProcess(
        processId: 100,
        bundleId: 'com.acme.helper',
        isProducingAudio: true,
      ),
      AudioCaptureProcess(
        processId: 101,
        bundleId: 'com.acme.Mail',
        isProducingAudio: true,
      ),
    ];

    expect(
      const SystemAudioProcessSelector().expandProcessIds(
        processes: processes,
        bundleIds: <String>['com.acme.helper'],
      ),
      <int>[100],
    );
  });

  test('helper bundle IDs are recognisable for display', () {
    expect(
      SystemAudioProcessSelector.isHelperBundleId(
        'com.microsoft.teams2.helper',
      ),
      isTrue,
    );
    expect(
      SystemAudioProcessSelector.isHelperBundleId(
        'com.google.Chrome.helper.gpu',
      ),
      isTrue,
    );
    expect(
      SystemAudioProcessSelector.isHelperBundleId('com.google.Chrome'),
      isFalse,
    );
  });
}
