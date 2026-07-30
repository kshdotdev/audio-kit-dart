import Foundation

#if os(macOS)
  /// A process-wide App Nap guard held while capture sessions are running.
  ///
  /// macOS throttles timers and coalesces IO for an app the user is not looking
  /// at, so an unfocused capture delivers its callbacks in bursts instead of at
  /// a steady realtime cadence. `ProcessInfo.beginActivity` opts the process out
  /// of that for as long as the assertion is held; `.latencyCritical` also keeps
  /// idle sleep away from the audio path.
  ///
  /// Adapted from Control Center (MIT © 2026 Samuel Alev).
  ///
  /// The assertion is refcounted: concurrent microphone and system-audio
  /// sessions hold exactly one activity between them, and it ends when the last
  /// session releases.
  final class CaptureActivity: @unchecked Sendable {
    static let shared = CaptureActivity()

    private let lock = NSLock()
    private var holders = 0
    private var activity: NSObjectProtocol?

    /// Begins the activity for the first holder. Balanced by `release()`.
    func acquire() {
      lock.lock()
      defer { lock.unlock() }
      holders += 1
      guard holders == 1, activity == nil else { return }
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "audio_flutter capture session"
      )
    }

    /// Ends the activity once the last holder releases it.
    func release() {
      lock.lock()
      defer { lock.unlock() }
      guard holders > 0 else { return }
      holders -= 1
      guard holders == 0, let activity else { return }
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
  }
#endif
