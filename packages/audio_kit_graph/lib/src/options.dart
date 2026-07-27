/// Behavior when a route's bounded mailbox is full.
enum AudioOverflowPolicy {
  /// Discard the oldest queued frame and accept the new frame.
  dropOldest,

  /// Discard the incoming frame.
  dropNewest,

  /// Fail only the overflowing route.
  failRoute,

  /// Wait for mailbox space.
  ///
  /// This is valid only when the router is configured for a pausable upstream.
  blockUpstream,
}

/// Immutable bounded-mailbox configuration for one route.
final class AudioRouteOptions {
  /// Creates route options.
  AudioRouteOptions({
    required this.capacityFrames,
    required this.overflowPolicy,
    this.capacitySampleFrames = 384000,
  }) {
    if (capacityFrames <= 0) {
      throw ArgumentError.value(
        capacityFrames,
        'capacityFrames',
        'Must be positive.',
      );
    }
    if (capacitySampleFrames <= 0) {
      throw ArgumentError.value(
        capacitySampleFrames,
        'capacitySampleFrames',
        'Must be positive.',
      );
    }
  }

  /// Maximum queued frames, excluding the frame currently being written.
  final int capacityFrames;

  /// Maximum PCM sample frames queued, excluding an in-flight write.
  ///
  /// This second bound prevents one unusually large frame from defeating the
  /// frame-count limit. The default is eight seconds at 48 kHz.
  final int capacitySampleFrames;

  /// Full-mailbox behavior.
  final AudioOverflowPolicy overflowPolicy;

  /// Lossless route that fails loudly instead of corrupting output.
  static AudioRouteOptions lossless({
    int capacityFrames = 64,
    int capacitySampleFrames = 384000,
  }) => AudioRouteOptions(
    capacityFrames: capacityFrames,
    capacitySampleFrames: capacitySampleFrames,
    overflowPolicy: AudioOverflowPolicy.failRoute,
  );

  /// Realtime analysis route that keeps the freshest bounded window.
  static AudioRouteOptions realtime({
    int capacityFrames = 8,
    int capacitySampleFrames = 384000,
  }) => AudioRouteOptions(
    capacityFrames: capacityFrames,
    capacitySampleFrames: capacitySampleFrames,
    overflowPolicy: AudioOverflowPolicy.dropOldest,
  );

  /// Latest-only route suitable for meters and waveform previews.
  static AudioRouteOptions latestOnly({int capacitySampleFrames = 384000}) =>
      AudioRouteOptions(
        capacityFrames: 1,
        capacitySampleFrames: capacitySampleFrames,
        overflowPolicy: AudioOverflowPolicy.dropOldest,
      );

  /// Backpressured route for finite, pausable sources.
  static AudioRouteOptions blocking({
    int capacityFrames = 8,
    int capacitySampleFrames = 384000,
  }) => AudioRouteOptions(
    capacityFrames: capacityFrames,
    capacitySampleFrames: capacitySampleFrames,
    overflowPolicy: AudioOverflowPolicy.blockUpstream,
  );
}

/// Outcome for one route during a router dispatch.
enum AudioDispatchOutcome { accepted, dropped, routeFailed, routeUnavailable }

/// Immutable per-route outcomes for one submitted frame.
final class AudioDispatchReport {
  /// Creates a dispatch report.
  AudioDispatchReport(Map<String, AudioDispatchOutcome> outcomes)
    : outcomes = Map<String, AudioDispatchOutcome>.unmodifiable(outcomes);

  /// Route ID to outcome, captured from the routes attached at submission time.
  final Map<String, AudioDispatchOutcome> outcomes;

  /// Whether every route accepted the frame.
  bool get acceptedByAll => outcomes.values.every(
    (outcome) => outcome == AudioDispatchOutcome.accepted,
  );
}
