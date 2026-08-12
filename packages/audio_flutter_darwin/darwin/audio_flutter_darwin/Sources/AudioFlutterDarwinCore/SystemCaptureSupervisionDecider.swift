import Foundation

/// Why a supervised system capture is being failed.
///
/// The two deaths are distinct diagnoses that used to collapse into one
/// failure, so they stay distinct all the way to the host: one says the HAL
/// never called us, the other says it called us and nothing survived the
/// converter.
public enum SystemCaptureDeath: Equatable {
  /// The aggregate reports its IO engine running while the IO proc has still
  /// never fired. A render-callback registration in that state is broken, and
  /// waiting cannot repair it.
  case renderCallbackNeverFired
  /// The device advanced [renderCycles] render cycles across two consecutive
  /// windows and no audio reached the assembler.
  case noAudioSurvivedConversion(renderCycles: Int64)
}

/// The per-window decision of the system-capture supervision loop.
///
/// The loop itself — its sleeps, its device probes, and its event emission —
/// stays in `SystemAudioCaptureSession`. What lives here is only the choice
/// each window makes from the counters it observed, so the shapes that shipped
/// as bugs (an armed tap waiting for its app's first sound being read as a
/// dead capture, a genuinely dead pipeline being read as "just silent") are
/// decidable without a HAL.
///
/// Counters are session-lifetime monotonic totals, never per-window deltas:
/// the assembler's counters survive a rebuild (`markSourceRestart` only flags
/// a discontinuity) and `renderCycles` counts every IO proc invocation since
/// the session started. Every comparison is therefore against a baseline
/// captured at supervision time, not against zero.
public struct SystemCaptureSupervisionDecider {
  /// What the supervisor read at the end of one window.
  public struct Window: Equatable {
    /// Converted buffers pushed into the assembler, session-lifetime.
    public let callbackCount: Int64
    /// Pushed buffers carrying at least one non-zero sample, session-lifetime.
    public let nonZeroFrameCount: Int64
    /// IO proc invocations, session-lifetime.
    public let renderCycles: Int64

    public init(
      callbackCount: Int64,
      nonZeroFrameCount: Int64,
      renderCycles: Int64
    ) {
      self.callbackCount = callbackCount
      self.nonZeroFrameCount = nonZeroFrameCount
      self.renderCycles = renderCycles
    }
  }

  /// What the very first window decides, before any rebuild has happened.
  public enum InitialOutcome: Equatable {
    /// Audio arrived within one window. Report health and stop supervising.
    case reportReceiving
    /// The chain is silent. Report the interruption and rebuild the tap once
    /// against a freshly resolved target set.
    case rebuildChain
  }

  /// What one post-rebuild window decides from its counters alone.
  public enum WindowOutcome: Equatable {
    /// Converted buffers arrived. Report health — `receivingAudio` separates
    /// real audio from an alive-but-silent tap — and stop supervising.
    case reportAliveAndStop(receivingAudio: Bool)
    /// The IO proc has not fired since the rebuild. The caller must read the
    /// device's running state and hand it back to [resolveIdleWindow]; only
    /// the device can tell an armed tap from a broken one.
    case probeDeviceRunning
    /// Fail the session.
    case escalateDead(SystemCaptureDeath)
    /// Nothing is decidable yet. Sleep another window.
    case keepWaiting
  }

  /// What an idle window decides once the device has been probed.
  public enum IdleOutcome: Equatable {
    /// Fail the session.
    case escalateDead(SystemCaptureDeath)
    /// Report `SystemCaptureAwaitingAppAudio` once, then keep waiting. The
    /// session stays alive: `kAudioAggregateDeviceTapAutoStartKey` arms the
    /// aggregate and the HAL defers its start until a tapped process receives
    /// its first audio, so a tap on an app that is not playing yet sits here
    /// indefinitely and begins delivering the moment sound arrives.
    case reportAwaitingAppAudio
    /// Already reported. Sleep another window.
    case keepWaiting
  }

  private let baselineCallbackCount: Int64
  private let baselineNonZeroFrameCount: Int64
  private let renderCyclesBaseline: Int64
  private var armedReported = false
  private var lastRenderCycles: Int64
  private var ranWithoutConvertedAudio = false

  /// - Parameters:
  ///   - baselineCallbackCount: assembler callbacks at the moment the rebuild
  ///     was decided, so callbacks landing while the new chain starts count as
  ///     progress instead of inflating a post-start baseline.
  ///   - baselineNonZeroFrameCount: non-zero buffers at that same moment.
  ///   - renderCyclesBaseline: IO proc invocations read once the rebuild
  ///     returned. Safe on the old chain's side (its teardown drains the IO
  ///     queue) and at worst counts a few of the new chain's earliest cycles,
  ///     which only delays the armed report by one window because converted
  ///     callbacks are checked first.
  public init(
    baselineCallbackCount: Int64,
    baselineNonZeroFrameCount: Int64,
    renderCyclesBaseline: Int64
  ) {
    self.baselineCallbackCount = baselineCallbackCount
    self.baselineNonZeroFrameCount = baselineNonZeroFrameCount
    self.renderCyclesBaseline = renderCyclesBaseline
    lastRenderCycles = renderCyclesBaseline
  }

  /// The decision of the first supervision window, which runs before any
  /// rebuild and only asks whether audio arrived at all.
  public static func initialOutcome(
    nonZeroFrameCount: Int64,
    baselineNonZeroFrameCount: Int64
  ) -> InitialOutcome {
    nonZeroFrameCount > baselineNonZeroFrameCount ? .reportReceiving : .rebuildChain
  }

  /// Decides one post-rebuild window from its counters.
  ///
  /// Converted callbacks are checked first, so a chain that came alive is
  /// never diagnosed from its render cycles. A window that returns
  /// [WindowOutcome.probeDeviceRunning] leaves the two-window "ran but
  /// produced nothing" state untouched — an idle device has not run, so it
  /// cannot have run without producing.
  public mutating func evaluate(_ window: Window) -> WindowOutcome {
    if window.callbackCount > baselineCallbackCount {
      return .reportAliveAndStop(
        receivingAudio: window.nonZeroFrameCount > baselineNonZeroFrameCount
      )
    }
    if window.renderCycles == renderCyclesBaseline {
      return .probeDeviceRunning
    }
    // The device ran but produced no converted audio. Require two consecutive
    // windows with the device still advancing before failing, so buffers in
    // flight through the converter don't count as death.
    if ranWithoutConvertedAudio, window.renderCycles > lastRenderCycles {
      return .escalateDead(
        .noAudioSurvivedConversion(renderCycles: window.renderCycles)
      )
    }
    ranWithoutConvertedAudio = true
    lastRenderCycles = window.renderCycles
    return .keepWaiting
  }

  /// Resolves a window that returned [WindowOutcome.probeDeviceRunning].
  ///
  /// - Parameters:
  ///   - deviceIsRunning: the HAL's view of the aggregate's IO engine, or
  ///     `nil` when the property could not be read (unknown or destroyed
  ///     device), which is never treated as death.
  ///   - renderCyclesAfterProbe: the cycle counter re-read after the probe.
  ///     Probing can race the chain coming alive, so a device that reports
  ///     running is only fatal if the IO proc still has not fired.
  public mutating func resolveIdleWindow(
    deviceIsRunning: Bool?,
    renderCyclesAfterProbe: Int64
  ) -> IdleOutcome {
    if deviceIsRunning == true, renderCyclesAfterProbe == renderCyclesBaseline {
      return .escalateDead(.renderCallbackNeverFired)
    }
    guard !armedReported else { return .keepWaiting }
    armedReported = true
    return .reportAwaitingAppAudio
  }
}
