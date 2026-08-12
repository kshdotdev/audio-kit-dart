import XCTest

@testable import AudioFlutterDarwinCore

/// The per-window decisions of microphone delivery supervision.
///
/// The invariant under test is that silence is health and only exhaustion is
/// fatal: one proven rebuild, or a bounded wait for a device that never
/// presents a usable format. A Bluetooth headset moving between its call and
/// media profiles spends several windows in exactly that state and must
/// survive it.
final class MicrophoneSupervisionDeciderTests: XCTestCase {
  /// The generation counter is session-lifetime, so supervision starts from
  /// whatever value the tap reinstalls have already reached.
  private let startGeneration: Int64 = 7

  private func makeDecider() -> MicrophoneSupervisionDecider {
    MicrophoneSupervisionDecider(tapGeneration: startGeneration)
  }

  private func silentWindow(
    generation: Int64? = nil
  ) -> MicrophoneSupervisionDecider.Window {
    MicrophoneSupervisionDecider.Window(
      renderCycles: 0,
      nonZeroFrameCount: 0,
      tapGeneration: generation ?? startGeneration
    )
  }

  // MARK: - Delivery proves the tap attached

  func testDeliveredBuffersWithAudioReportReceiving() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        MicrophoneSupervisionDecider.Window(
          renderCycles: 3,
          nonZeroFrameCount: 2,
          tapGeneration: startGeneration
        )
      ),
      .reportAliveAndStop(receivingAudio: true)
    )
  }

  /// A muted or very quiet microphone delivers buffers of zeroes. That is
  /// health, not failure.
  func testDeliveredSilenceIsHealthNotFailure() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        MicrophoneSupervisionDecider.Window(
          renderCycles: 3,
          nonZeroFrameCount: 0,
          tapGeneration: startGeneration
        )
      ),
      .reportAliveAndStop(receivingAudio: false)
    )
  }

  // MARK: - The single rebuild budget

  func testFirstSilentWindowReportsSilenceAndRebuilds() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(silentWindow()),
      .reinstallTap(reportSilence: true)
    )
  }

  func testSilenceIsReportedOnlyOnce() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(silentWindow()),
      .reinstallTap(reportSilence: true)
    )
    XCTAssertEqual(
      decider.resolveReinstall(.skipped, tapGeneration: startGeneration),
      .reportAwaitingInputFormat
    )
    XCTAssertEqual(
      decider.evaluate(silentWindow()),
      .reinstallTap(reportSilence: false)
    )
  }

  /// A rebuild that actually happened, followed by another silent window, is
  /// the one way delivery supervision fails a chain.
  func testSilenceAfterAProvenRebuildIsDead() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(silentWindow()),
      .reinstallTap(reportSilence: true)
    )
    XCTAssertEqual(
      decider.resolveReinstall(.reinstalled, tapGeneration: startGeneration + 1),
      .keepWaiting
    )
    XCTAssertEqual(
      decider.evaluate(silentWindow(generation: startGeneration + 1)),
      .escalateDead
    )
  }

  /// The reinstall's own bump must not read as somebody else's rebuild in the
  /// next window, or the budget could never be spent.
  func testOwnReinstallGenerationBumpDoesNotRestartSupervision() {
    var decider = makeDecider()

    _ = decider.evaluate(silentWindow())
    _ = decider.resolveReinstall(.reinstalled, tapGeneration: startGeneration + 1)

    XCTAssertEqual(
      decider.evaluate(silentWindow(generation: startGeneration + 1)),
      .escalateDead
    )
  }

  func testFailedReinstallStopsSupervision() {
    var decider = makeDecider()

    _ = decider.evaluate(silentWindow())

    XCTAssertEqual(
      decider.resolveReinstall(.failed, tapGeneration: startGeneration),
      .stop
    )
  }

  // MARK: - Windows with no usable input format

  /// The rebuild budget is untouched by a skipped reinstall: nothing was
  /// repaired, so nothing was proven, so no window may be failed as
  /// `MicrophoneCaptureDead`.
  func testUnusableFormatWindowsDoNotConsumeTheRebuildBudget() {
    var decider = makeDecider()

    for windowIndex in 0..<(MicrophoneSupervisionDecider.maximumUnusableFormatWindows - 1) {
      XCTAssertEqual(
        decider.evaluate(silentWindow()),
        .reinstallTap(reportSilence: windowIndex == 0),
        "window \(windowIndex) must still attempt the rebuild it is owed"
      )
      XCTAssertEqual(
        decider.resolveReinstall(.skipped, tapGeneration: startGeneration),
        windowIndex == 0 ? .reportAwaitingInputFormat : .keepWaiting,
        "window \(windowIndex)"
      )
    }
  }

  /// A device that eventually presents a format still gets its one proven
  /// rebuild, and the session survives.
  func testFormatArrivingAfterSkippedWindowsStillSpendsTheBudget() {
    var decider = makeDecider()

    for _ in 0..<3 {
      _ = decider.evaluate(silentWindow())
      _ = decider.resolveReinstall(.skipped, tapGeneration: startGeneration)
    }

    XCTAssertEqual(
      decider.evaluate(silentWindow()),
      .reinstallTap(reportSilence: false)
    )
    XCTAssertEqual(
      decider.resolveReinstall(.reinstalled, tapGeneration: startGeneration + 1),
      .keepWaiting
    )
    XCTAssertEqual(
      decider.evaluate(silentWindow(generation: startGeneration + 1)),
      .escalateDead
    )
  }

  /// The bounded wait ends the session on the fifth consecutive unusable
  /// window, and not before.
  func testFiveUnusableFormatWindowsEscalate() {
    var decider = makeDecider()
    var resolutions: [MicrophoneSupervisionDecider.ReinstallResolution] = []

    for _ in 0..<MicrophoneSupervisionDecider.maximumUnusableFormatWindows {
      XCTAssertNotEqual(decider.evaluate(silentWindow()), .escalateDead)
      resolutions.append(
        decider.resolveReinstall(.skipped, tapGeneration: startGeneration)
      )
    }

    XCTAssertEqual(
      resolutions,
      [
        .reportAwaitingInputFormat,
        .keepWaiting,
        .keepWaiting,
        .keepWaiting,
        .escalateInputFormatUnavailable,
      ]
    )
  }

  func testMaximumUnusableFormatWindowsIsFive() {
    XCTAssertEqual(MicrophoneSupervisionDecider.maximumUnusableFormatWindows, 5)
  }

  // MARK: - A configuration-change recovery restarting supervision

  /// A tap rebuilt inside the window by the configuration-change observer must
  /// be judged on a window of its own, not on the dead chain it replaced.
  func testMidWindowRebuildRestartsSupervision() {
    var decider = makeDecider()

    _ = decider.evaluate(silentWindow())
    _ = decider.resolveReinstall(.reinstalled, tapGeneration: startGeneration + 1)

    XCTAssertEqual(
      decider.evaluate(silentWindow(generation: startGeneration + 2)),
      .keepWaiting,
      "the recovery's chain has not had a window of its own yet"
    )
    XCTAssertEqual(
      decider.evaluate(silentWindow(generation: startGeneration + 2)),
      .escalateDead,
      "the extra window is one window, not an exemption"
    )
  }

  /// The generation change also clears the unusable-format counter, so a
  /// device that keeps transitioning cannot accumulate its way to a failure.
  func testMidWindowRebuildClearsTheUnusableFormatCounter() {
    var decider = makeDecider()

    for _ in 0..<(MicrophoneSupervisionDecider.maximumUnusableFormatWindows - 1) {
      _ = decider.evaluate(silentWindow())
      _ = decider.resolveReinstall(.skipped, tapGeneration: startGeneration)
    }

    XCTAssertEqual(
      decider.evaluate(silentWindow(generation: startGeneration + 1)),
      .keepWaiting
    )

    var resolutions: [MicrophoneSupervisionDecider.ReinstallResolution] = []
    for _ in 0..<(MicrophoneSupervisionDecider.maximumUnusableFormatWindows - 1) {
      _ = decider.evaluate(silentWindow(generation: startGeneration + 1))
      resolutions.append(
        decider.resolveReinstall(.skipped, tapGeneration: startGeneration + 1)
      )
    }

    XCTAssertEqual(
      resolutions,
      [.keepWaiting, .keepWaiting, .keepWaiting, .keepWaiting],
      "the counter restarted, and the awaiting-format event stays once-only"
    )
  }
}
