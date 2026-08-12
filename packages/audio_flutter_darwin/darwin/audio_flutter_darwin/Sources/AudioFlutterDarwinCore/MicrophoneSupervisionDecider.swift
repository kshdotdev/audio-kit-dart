import Foundation

/// The per-window decision of the microphone delivery watchdog.
///
/// `AVAudioEngine.start()` succeeds even when `installTap` lost a race with a
/// hardware format transition — the HAL logs a format mismatch and refuses the
/// tap, the engine reports no error, and the session records zero frames. A
/// started engine therefore proves nothing; one delivered buffer does.
///
/// Silence is health, never failure: a muted or very quiet microphone is
/// legitimate, so only the total absence of buffers is fatal, and only through
/// one of two exhaustion conditions:
///
/// - A rebuild that actually happened, followed by another silent window. The
///   chain was repaired against a freshly read format and still delivers
///   nothing, so it is dead (`MicrophoneCaptureDead`).
/// - [maximumUnusableFormatWindows] consecutive windows in which the input
///   node never presented a usable format, so no rebuild could even be
///   attempted. The device is gone rather than broken
///   (`MicrophoneInputFormatUnavailable`).
///
/// A rebuild skipped for want of a usable format therefore costs nothing from
/// the single-rebuild budget — nothing was repaired, so nothing was proven —
/// and a configuration-change recovery that rebuilds the tap inside a window
/// restarts supervision outright, clearing the unusable-format counter.
/// Neither can fail a session that is merely mid-transition, which is exactly
/// the state a Bluetooth headset moving between its call and media profiles
/// spends several windows in.
///
/// The loop, its sleeps, the tap reinstall itself, and event emission stay in
/// `MicrophoneCaptureSession`; only the choice each window makes lives here.
public struct MicrophoneSupervisionDecider {
  /// Consecutive silent windows tolerated while the input node keeps reporting
  /// no usable format, so a device that never returns still ends the session
  /// instead of supervising forever.
  public static let maximumUnusableFormatWindows = 5

  /// What the watchdog read at the end of one window.
  public struct Window: Equatable {
    /// Tap callbacks since the session started. Anything above zero proves the
    /// tap attached, which is the only thing this watchdog is looking for.
    public let renderCycles: Int64
    /// Buffers carrying at least one non-zero sample, zero when the assembler
    /// is gone.
    public let nonZeroFrameCount: Int64
    /// The tap-generation counter, bumped by every completed reinstall. It is
    /// what tells "this chain was just rebuilt" from "this chain is dead".
    public let tapGeneration: Int64

    public init(
      renderCycles: Int64,
      nonZeroFrameCount: Int64,
      tapGeneration: Int64
    ) {
      self.renderCycles = renderCycles
      self.nonZeroFrameCount = nonZeroFrameCount
      self.tapGeneration = tapGeneration
    }
  }

  /// What one window decides from its counters alone.
  public enum WindowOutcome: Equatable {
    /// Buffers arrived. Report health — `receivingAudio` separates real audio
    /// from an active but silent microphone — and stop supervising.
    case reportAliveAndStop(receivingAudio: Bool)
    /// Sleep another window. Either a configuration-change recovery rebuilt
    /// the tap inside this window, so the new chain is judged on a window of
    /// its own, or there is simply nothing to decide yet.
    case keepWaiting
    /// The single rebuild was spent and the tap still delivers nothing. Fail
    /// the session as `MicrophoneCaptureDead`.
    case escalateDead
    /// Reinstall the tap and hand the result to [resolveReinstall].
    /// `reportSilence` is true exactly once per session, for the
    /// `MicrophoneTapSilent` event that precedes the first rebuild attempt.
    case reinstallTap(reportSilence: Bool)
  }

  /// The tap reinstall's own report, mirroring
  /// `MicrophoneCaptureSession.TapReinstallOutcome`.
  public enum ReinstallOutcome: Equatable {
    /// The tap was reinstalled against a freshly read hardware format.
    case reinstalled
    /// Nothing was changed: the session is stopping, or the input node reports
    /// no usable format yet and the existing tap is the better of the two.
    case skipped
    /// The reinstall could not complete and the session has been failed.
    case failed
  }

  /// What to do once the reinstall reported back.
  public enum ReinstallResolution: Equatable {
    /// The reinstall already failed the session. Stop supervising.
    case stop
    /// Sleep another window.
    case keepWaiting
    /// Report `MicrophoneAwaitingInputFormat` once, then keep waiting.
    case reportAwaitingInputFormat
    /// The input node never presented a usable format. Fail the session as
    /// `MicrophoneInputFormatUnavailable`.
    case escalateInputFormatUnavailable
  }

  private var rebuilt = false
  private var reportedSilence = false
  private var reportedMissingFormat = false
  private var unusableFormatWindows = 0
  private var generation: Int64

  /// - Parameter tapGeneration: the generation counter read once, before the
  ///   first window, so a reinstall that lands mid-window is detected.
  public init(tapGeneration: Int64) {
    generation = tapGeneration
  }

  /// Decides one window from its counters.
  ///
  /// A generation change is checked before the rebuild budget: a chain that
  /// was just repaired by a configuration-change recovery has not had a window
  /// of its own yet, and must not be judged on the dead one it replaced.
  public mutating func evaluate(_ window: Window) -> WindowOutcome {
    if window.renderCycles > 0 {
      return .reportAliveAndStop(receivingAudio: window.nonZeroFrameCount > 0)
    }
    if window.tapGeneration != generation {
      generation = window.tapGeneration
      unusableFormatWindows = 0
      return .keepWaiting
    }
    if rebuilt { return .escalateDead }
    let reportSilence = !reportedSilence
    reportedSilence = true
    return .reinstallTap(reportSilence: reportSilence)
  }

  /// Resolves a window that returned [WindowOutcome.reinstallTap].
  ///
  /// - Parameters:
  ///   - outcome: what the reinstall reported.
  ///   - tapGeneration: the generation counter re-read after the reinstall,
  ///     used only when the tap was actually reinstalled — that bump is this
  ///     supervisor's own and must not read as somebody else's rebuild in the
  ///     next window.
  public mutating func resolveReinstall(
    _ outcome: ReinstallOutcome,
    tapGeneration: Int64
  ) -> ReinstallResolution {
    switch outcome {
    case .failed:
      return .stop
    case .reinstalled:
      rebuilt = true
      unusableFormatWindows = 0
      generation = tapGeneration
      return .keepWaiting
    case .skipped:
      // Nothing was torn down or rebuilt: the input node reports no usable
      // format yet, or the session is stopping. The one rebuild is still owed,
      // so the budget stays intact and only the bounded wait advances.
      unusableFormatWindows += 1
      if unusableFormatWindows >= Self.maximumUnusableFormatWindows {
        return .escalateInputFormatUnavailable
      }
      guard !reportedMissingFormat else { return .keepWaiting }
      reportedMissingFormat = true
      return .reportAwaitingInputFormat
    }
  }
}
