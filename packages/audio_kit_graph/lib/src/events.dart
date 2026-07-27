import 'package:audio_core/audio_core.dart';

import 'metrics.dart';

/// Lifecycle state of a dynamically attached route.
enum AudioRouteState { attached, draining, finished, aborted, failed }

/// Typed event emitted by an audio route and its parent router.
sealed class AudioRouteEvent {
  /// Creates a route event.
  const AudioRouteEvent({required this.routeId, required this.timestamp});

  /// Stable route identifier.
  final String routeId;

  /// Monotonic time at which the event was emitted.
  final Duration timestamp;
}

/// Route lifecycle changed.
final class AudioRouteStateChanged extends AudioRouteEvent {
  /// Creates a state event.
  const AudioRouteStateChanged({
    required super.routeId,
    required super.timestamp,
    required this.state,
  });

  /// New route state.
  final AudioRouteState state;
}

/// One or more frames were discarded by an overflow policy.
final class AudioRouteGap extends AudioRouteEvent {
  /// Creates exact discarded-range metadata.
  const AudioRouteGap({
    required super.routeId,
    required super.timestamp,
    required this.firstSequence,
    required this.lastSequence,
    required this.firstSampleOffset,
    required this.endSampleOffset,
    required this.droppedFrames,
    required this.droppedSampleFrames,
  });

  /// First discarded source sequence.
  final int firstSequence;

  /// Last discarded source sequence.
  final int lastSequence;

  /// First discarded sample-frame offset.
  final int firstSampleOffset;

  /// Exclusive end offset of the discarded range.
  final int endSampleOffset;

  /// Number of discarded frames represented by this event.
  final int droppedFrames;

  /// Number of discarded interleaved sample frames.
  final int droppedSampleFrames;
}

/// Route failed without terminating sibling routes.
final class AudioRouteFailed extends AudioRouteEvent {
  /// Creates a route failure event.
  const AudioRouteFailed({
    required super.routeId,
    required super.timestamp,
    required this.failure,
  });

  /// Structured routing failure.
  final AudioFailure failure;
}

/// A route metrics snapshot was requested or reached a terminal state.
final class AudioRouteMetricsUpdated extends AudioRouteEvent {
  /// Creates a metrics event.
  const AudioRouteMetricsUpdated({
    required super.routeId,
    required super.timestamp,
    required this.metrics,
  });

  /// Immutable metrics snapshot.
  final AudioRouteMetrics metrics;
}
