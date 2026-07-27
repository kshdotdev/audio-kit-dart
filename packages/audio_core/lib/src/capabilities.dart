/// Features a prepared source session can safely provide.
final class AudioSourceCapabilities {
  /// Creates source capability metadata.
  const AudioSourceCapabilities({
    required this.isRealtime,
    this.supportsPause = false,
  });

  /// Whether frames arrive according to a live wall clock.
  final bool isRealtime;

  /// Whether [AudioSourceSession.pause] applies backpressure at the source.
  final bool supportsPause;

  /// Typical live capture capabilities.
  static const AudioSourceCapabilities realtime = AudioSourceCapabilities(
    isRealtime: true,
  );

  /// Typical finite or synthesized source capabilities.
  static const AudioSourceCapabilities pausable = AudioSourceCapabilities(
    isRealtime: false,
    supportsPause: true,
  );
}

/// Features provided by a sink implementation.
final class AudioSinkCapabilities {
  /// Creates sink capability metadata.
  const AudioSinkCapabilities({this.requiresSequentialWrites = true});

  /// Whether callers must wait for each write before issuing the next.
  final bool requiresSequentialWrites;

  /// Default sequential sink behavior.
  static const AudioSinkCapabilities sequential = AudioSinkCapabilities();
}
