/// Immutable counters for one audio route.
final class AudioRouteMetrics {
  /// Creates a metrics snapshot.
  const AudioRouteMetrics({
    required this.routeId,
    required this.acceptedFrames,
    required this.deliveredFrames,
    required this.deliveredSampleFrames,
    required this.droppedFrames,
    required this.droppedSampleFrames,
    required this.currentDepth,
    required this.highWaterMark,
    required this.currentQueuedSampleFrames,
    required this.queuedSampleFramesHighWaterMark,
    required this.failureCount,
  });

  /// Stable route identifier.
  final String routeId;

  /// Frames admitted to the bounded mailbox.
  final int acceptedFrames;

  /// Frames successfully written to the target.
  final int deliveredFrames;

  /// PCM sample frames successfully written to the target.
  final int deliveredSampleFrames;

  /// Frames rejected or evicted by an overflow policy.
  final int droppedFrames;

  /// PCM sample frames rejected or evicted by overflow.
  final int droppedSampleFrames;

  /// Frames currently waiting in the mailbox.
  final int currentDepth;

  /// Largest observed [currentDepth].
  final int highWaterMark;

  /// PCM sample frames currently waiting in the mailbox.
  final int currentQueuedSampleFrames;

  /// Largest observed [currentQueuedSampleFrames].
  final int queuedSampleFramesHighWaterMark;

  /// Number of terminal route failures.
  final int failureCount;
}
