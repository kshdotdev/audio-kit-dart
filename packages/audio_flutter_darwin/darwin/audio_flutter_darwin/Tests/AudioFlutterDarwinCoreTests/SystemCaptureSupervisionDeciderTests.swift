import XCTest

@testable import AudioFlutterDarwinCore

/// The per-window decisions of system-capture supervision.
///
/// Two of these scenarios shipped as bugs: an armed tap waiting for its app's
/// first sound was failed as a dead capture, and a genuinely dead pipeline was
/// reported as merely silent.
final class SystemCaptureSupervisionDeciderTests: XCTestCase {
  /// Counters are session-lifetime totals, so every scenario runs against a
  /// non-zero baseline — a decider that compared against zero would pass with
  /// zeroed baselines and fail in production.
  private let baselineCallbacks: Int64 = 120
  private let baselineNonZero: Int64 = 90
  private let baselineCycles: Int64 = 4200

  private func makeDecider() -> SystemCaptureSupervisionDecider {
    SystemCaptureSupervisionDecider(
      baselineCallbackCount: baselineCallbacks,
      baselineNonZeroFrameCount: baselineNonZero,
      renderCyclesBaseline: baselineCycles
    )
  }

  private func window(
    callbacks: Int64,
    nonZero: Int64,
    cycles: Int64
  ) -> SystemCaptureSupervisionDecider.Window {
    SystemCaptureSupervisionDecider.Window(
      callbackCount: callbacks,
      nonZeroFrameCount: nonZero,
      renderCycles: cycles
    )
  }

  // MARK: - The first window, before any rebuild

  func testFirstWindowWithNewAudioReportsReceiving() {
    XCTAssertEqual(
      SystemCaptureSupervisionDecider.initialOutcome(
        nonZeroFrameCount: 91,
        baselineNonZeroFrameCount: 90
      ),
      .reportReceiving
    )
  }

  func testFirstSilentWindowRebuildsTheChain() {
    XCTAssertEqual(
      SystemCaptureSupervisionDecider.initialOutcome(
        nonZeroFrameCount: 90,
        baselineNonZeroFrameCount: 90
      ),
      .rebuildChain
    )
  }

  // MARK: - Armed tap: the aggregate waiting for its app's first sound

  /// The shipped bug. `kAudioAggregateDeviceTapAutoStartKey` defers the
  /// aggregate's start until a tapped process plays, so zero callbacks with
  /// zero render cycles on a device that is not running is a waiting state.
  func testArmedTapWithNoCallbacksAndNoCyclesAwaitsRatherThanDies() {
    var decider = makeDecider()

    let outcome = decider.evaluate(
      window(callbacks: baselineCallbacks, nonZero: baselineNonZero, cycles: baselineCycles)
    )
    XCTAssertEqual(outcome, .probeDeviceRunning)

    let idle = decider.resolveIdleWindow(
      deviceIsRunning: false,
      renderCyclesAfterProbe: baselineCycles
    )
    XCTAssertEqual(idle, .reportAwaitingAppAudio)
  }

  func testAwaitingAppAudioIsReportedOnlyOnce() {
    var decider = makeDecider()

    for windowIndex in 0..<4 {
      XCTAssertEqual(
        decider.evaluate(
          window(
            callbacks: baselineCallbacks,
            nonZero: baselineNonZero,
            cycles: baselineCycles
          )
        ),
        .probeDeviceRunning,
        "window \(windowIndex)"
      )
      let idle = decider.resolveIdleWindow(
        deviceIsRunning: false,
        renderCyclesAfterProbe: baselineCycles
      )
      XCTAssertEqual(
        idle,
        windowIndex == 0 ? .reportAwaitingAppAudio : .keepWaiting,
        "window \(windowIndex)"
      )
    }
  }

  /// An unreadable `kAudioDevicePropertyDeviceIsRunning` (destroyed or unknown
  /// device) is never evidence of death.
  func testUnreadableDeviceStateAwaitsRatherThanDies() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles
        )
      ),
      .probeDeviceRunning
    )
    XCTAssertEqual(
      decider.resolveIdleWindow(
        deviceIsRunning: nil,
        renderCyclesAfterProbe: baselineCycles
      ),
      .reportAwaitingAppAudio
    )
  }

  /// An armed tap that starts delivering keeps the session, which is the whole
  /// point of not failing it while it waits.
  func testArmedTapThatStartsDeliveringReportsAlive() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles
        )
      ),
      .probeDeviceRunning
    )
    _ = decider.resolveIdleWindow(
      deviceIsRunning: false,
      renderCyclesAfterProbe: baselineCycles
    )

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks + 40,
          nonZero: baselineNonZero + 40,
          cycles: baselineCycles + 96
        )
      ),
      .reportAliveAndStop(receivingAudio: true)
    )
  }

  // MARK: - A device that reports running while its IO proc never fires

  func testRunningDeviceWithNoRenderCyclesIsDead() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles
        )
      ),
      .probeDeviceRunning
    )
    XCTAssertEqual(
      decider.resolveIdleWindow(
        deviceIsRunning: true,
        renderCyclesAfterProbe: baselineCycles
      ),
      .escalateDead(.renderCallbackNeverFired)
    )
  }

  /// The probe can race the chain coming alive, so the cycle counter is re-read
  /// after it. A device that started rendering during the probe is not dead.
  func testRunningDeviceThatRenderedDuringTheProbeIsNotDead() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles
        )
      ),
      .probeDeviceRunning
    )
    XCTAssertEqual(
      decider.resolveIdleWindow(
        deviceIsRunning: true,
        renderCyclesAfterProbe: baselineCycles + 1
      ),
      .reportAwaitingAppAudio
    )
  }

  // MARK: - A device that runs while nothing survives conversion

  func testTwoAdvancingWindowsWithoutConvertedAudioAreDead() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles + 96
        )
      ),
      .keepWaiting,
      "one window of buffers in flight through the converter is not death"
    )
    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles + 192
        )
      ),
      .escalateDead(.noAudioSurvivedConversion(renderCycles: baselineCycles + 192))
    )
  }

  /// A device that stopped advancing between the two windows has not proven
  /// itself broken, only stalled, so it keeps waiting.
  func testStalledCyclesWithoutConvertedAudioKeepWaiting() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles + 96
        )
      ),
      .keepWaiting
    )
    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles + 96
        )
      ),
      .keepWaiting
    )
  }

  /// Converted callbacks are checked before render cycles, so a chain that came
  /// alive in its second window is reported alive rather than diagnosed.
  func testConvertedAudioInTheSecondWindowWinsOverTheDeathCheck() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles + 96
        )
      ),
      .keepWaiting
    )
    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks + 1,
          nonZero: baselineNonZero,
          cycles: baselineCycles + 192
        )
      ),
      .reportAliveAndStop(receivingAudio: false)
    )
  }

  // MARK: - Alive-but-silent versus receiving

  func testCallbacksWithoutNonZeroFramesReportAliveButSilent() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks + 10,
          nonZero: baselineNonZero,
          cycles: baselineCycles + 20
        )
      ),
      .reportAliveAndStop(receivingAudio: false)
    )
  }

  /// Baselines are compared strictly: counters that merely equal the baseline
  /// carry no post-rebuild progress.
  func testCountersEqualToTheBaselineAreNotProgress() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks,
          nonZero: baselineNonZero,
          cycles: baselineCycles + 5
        )
      ),
      .keepWaiting
    )
  }

  func testNonZeroFramesEqualToTheBaselineReportSilent() {
    var decider = makeDecider()

    XCTAssertEqual(
      decider.evaluate(
        window(
          callbacks: baselineCallbacks + 1,
          nonZero: baselineNonZero,
          cycles: baselineCycles + 1
        )
      ),
      .reportAliveAndStop(receivingAudio: false)
    )
  }
}
