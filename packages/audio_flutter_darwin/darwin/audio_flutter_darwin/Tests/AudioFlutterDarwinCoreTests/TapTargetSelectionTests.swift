#if os(macOS)
  import CoreAudio
  import XCTest

  @testable import AudioFlutterDarwinCore

  /// Which process objects a requested target set resolves to.
  ///
  /// Getting this wrong taps the wrong process — the shape of a capture that
  /// arms, reports healthy, and records nothing, because an Electron app's
  /// audio lives in a helper process rather than in the process that owns the
  /// bundle ID.
  final class TapTargetSelectionTests: XCTestCase {
    private let unknown = AudioObjectID(kAudioObjectUnknown)

    private func process(
      _ object: AudioObjectID,
      _ bundleId: String
    ) -> TapCandidateProcess {
      TapCandidateProcess(object: object, bundleId: bundleId)
    }

    // MARK: - Sanitizing the requested bundle IDs

    func testEmptyBundleIdsAreDropped() {
      XCTAssertEqual(
        TapTargetSelection.sanitizedBundleIds(["", "com.acme.app", ""]),
        ["com.acme.app"]
      )
      XCTAssertEqual(TapTargetSelection.sanitizedBundleIds(["", ""]), [])
    }

    // MARK: - The bundle-ID namespace rule

    func testExactBundleIdMatches() {
      let objects = TapTargetSelection.processObjects(
        matchingBundleIds: ["com.acme.app"],
        in: [process(11, "com.acme.app"), process(12, "com.other.app")]
      )

      XCTAssertEqual(objects, [11])
    }

    /// The reason the rule exists: an Electron app plays through a helper in
    /// its own namespace.
    func testHelperNamespaceMatches() {
      let objects = TapTargetSelection.processObjects(
        matchingBundleIds: ["com.acme.app"],
        in: [
          process(11, "com.acme.app"),
          process(12, "com.acme.app.helper"),
          process(13, "com.acme.app.helper.renderer"),
        ]
      )

      XCTAssertEqual(objects, [11, 12, 13])
    }

    func testMatchingIsCaseInsensitive() {
      let objects = TapTargetSelection.processObjects(
        matchingBundleIds: ["COM.Acme.App"],
        in: [process(11, "com.acme.APP"), process(12, "com.acme.app.Helper")]
      )

      XCTAssertEqual(objects, [11, 12])
    }

    /// A different app whose bundle ID merely starts with the same characters
    /// is not in the namespace: the separator is required.
    func testPrefixWithoutSeparatorDoesNotMatch() {
      let objects = TapTargetSelection.processObjects(
        matchingBundleIds: ["com.acme.app"],
        in: [process(11, "com.acme.application"), process(12, "com.acme.appx")]
      )

      XCTAssertEqual(objects, [])
    }

    /// An unidentifiable process is not a wildcard.
    func testProcessesWithoutABundleIdNeverMatch() {
      let objects = TapTargetSelection.processObjects(
        matchingBundleIds: ["com.acme.app"],
        in: [process(11, ""), process(12, "com.acme.app")]
      )

      XCTAssertEqual(objects, [12])
    }

    func testNoRequestedBundleIdsMatchNothing() {
      XCTAssertEqual(
        TapTargetSelection.processObjects(
          matchingBundleIds: [],
          in: [process(11, "com.acme.app")]
        ),
        []
      )
    }

    func testEveryRequestedBundleIdContributes() {
      let objects = TapTargetSelection.processObjects(
        matchingBundleIds: ["com.acme.app", "com.other.app"],
        in: [
          process(11, "com.acme.app"),
          process(12, "com.third.app"),
          process(13, "com.other.app.helper"),
        ]
      )

      XCTAssertEqual(objects, [11, 13])
    }

    // MARK: - The union the tap is built from

    func testBundleMatchesAndProcessIdsAreUnionedInOrder() {
      let objects = TapTargetSelection.tapTargetObjects(
        bundleMatches: [11, 12],
        processIds: [501, 502],
        translate: { pid in AudioObjectID(pid) }
      )

      XCTAssertEqual(objects, [11, 12, 501, 502])
    }

    /// The same helper can be reached both ways, and a `CATapDescription` must
    /// not name it twice.
    func testDuplicatesAcrossBothSourcesAreCollapsed() {
      let objects = TapTargetSelection.tapTargetObjects(
        bundleMatches: [11, 12, 11],
        processIds: [11, 12, 13],
        translate: { pid in AudioObjectID(pid) }
      )

      XCTAssertEqual(objects, [11, 12, 13])
    }

    /// A PID the audio server has no object for is not tappable.
    func testUntranslatablePidsAreDropped() {
      let objects = TapTargetSelection.tapTargetObjects(
        bundleMatches: [11],
        processIds: [501, 502],
        translate: { pid in pid == 501 ? self.unknown : AudioObjectID(pid) }
      )

      XCTAssertEqual(objects, [11, 502])
    }

    /// A process ID that cannot be represented as a `pid_t` never reaches the
    /// audio server.
    func testProcessIdsOutsidePidRangeAreDropped() {
      var translated: [pid_t] = []
      let objects = TapTargetSelection.tapTargetObjects(
        bundleMatches: [],
        processIds: [Int64(Int32.max) + 1, -1, 502],
        translate: { pid in
          translated.append(pid)
          return AudioObjectID(bitPattern: Int32(pid))
        }
      )

      XCTAssertEqual(translated, [-1, 502])
      XCTAssertEqual(objects, [AudioObjectID(bitPattern: Int32(-1)), 502])
    }

    func testNoTargetsResolveToNoObjects() {
      XCTAssertEqual(
        TapTargetSelection.tapTargetObjects(
          bundleMatches: [],
          processIds: [],
          translate: { _ in self.unknown }
        ),
        []
      )
    }
  }
#endif
