import Foundation

#if os(macOS)
  import CoreAudio

  /// One process the audio server knows about, reduced to the facts a tap
  /// target selection is made on.
  ///
  /// The full enumeration (PID, bundle ID, output-running flag) is read by
  /// `SystemAudioCaptureSession.processObjects()`; this is the projection the
  /// selection math needs.
  public struct TapCandidateProcess: Equatable {
    public let object: AudioObjectID
    public let bundleId: String

    public init(object: AudioObjectID, bundleId: String) {
      self.object = object
      self.bundleId = bundleId
    }
  }

  /// Which Core Audio process objects a capture's requested target set
  /// resolves to, with no property reads of its own.
  ///
  /// The process enumeration, PID translation, `CATapDescription`
  /// construction, and the macOS 26 identity list stay in
  /// `SystemAudioCaptureSession`. What lives here is the filtering and
  /// de-duplication those steps feed on, which is what decides whether a
  /// selection ends up tapping the right helper process.
  public enum TapTargetSelection {
    /// The requested bundle IDs with empty entries dropped.
    ///
    /// An empty string matches nothing and would silently widen a selection if
    /// it were allowed to reach the namespace rule as a prefix.
    public static func sanitizedBundleIds(_ bundleIds: [String]) -> [String] {
      bundleIds.filter { !$0.isEmpty }
    }

    /// The process objects that belong to [bundleIds] right now.
    ///
    /// A bundle ID owns its own process and its helper namespace (`id.*`),
    /// matched case-insensitively — never a different app whose bundle ID
    /// merely starts with the same characters (`com.acme.app` never matches
    /// `com.acme.apple`). This mirrors the Dart selector's namespace rule, and
    /// matching the namespace natively also catches helpers that spawned after
    /// the host expanded its selection.
    ///
    /// Processes with no bundle ID are never matched: an empty candidate is
    /// unidentifiable, not a wildcard.
    public static func processObjects(
      matchingBundleIds bundleIds: [String],
      in processes: [TapCandidateProcess]
    ) -> [AudioObjectID] {
      guard !bundleIds.isEmpty else { return [] }
      let targets = bundleIds.map { $0.lowercased() }
      return processes.compactMap { process in
        let candidate = process.bundleId.lowercased()
        guard !candidate.isEmpty else { return nil }
        let matches = targets.contains { target in
          candidate == target || candidate.hasPrefix(target + ".")
        }
        return matches ? process.object : nil
      }
    }

    /// The authorized target set: the objects that own the requested bundle
    /// IDs unioned with the objects the host's process IDs translate to.
    ///
    /// The union is ordered — bundle matches first, then process IDs in the
    /// order they were requested — and de-duplicated, because the same helper
    /// can be reached both ways and a `CATapDescription` must not name it
    /// twice. Process IDs that do not fit `pid_t`, and PIDs the audio server
    /// has no object for, drop out: they are unrepresentable rather than
    /// tappable.
    ///
    /// - Parameter translate: resolves a PID to its Core Audio process object,
    ///   returning `kAudioObjectUnknown` when the audio server knows no such
    ///   process.
    public static func tapTargetObjects(
      bundleMatches: [AudioObjectID],
      processIds: [Int64],
      translate: (pid_t) -> AudioObjectID
    ) -> [AudioObjectID] {
      var objects: [AudioObjectID] = []
      var seen = Set<AudioObjectID>()
      for object
        in bundleMatches
        + processIds.compactMap({ value -> AudioObjectID? in
          guard let pid = pid_t(exactly: value) else { return nil }
          let object = translate(pid)
          return object == AudioObjectID(kAudioObjectUnknown) ? nil : object
        })
      {
        if seen.insert(object).inserted {
          objects.append(object)
        }
      }
      return objects
    }
  }
#endif
