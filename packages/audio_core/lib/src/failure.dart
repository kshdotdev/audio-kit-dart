/// Stable stage at which an audio operation failed.
enum AudioFailureStage {
  preparation,
  startup,
  capture,
  processing,
  routing,
  encoding,
  playback,
  shutdown,
  provider,
  unknown,
}

/// Provider-neutral failure safe to cross package and isolate boundaries.
final class AudioFailure implements Exception {
  /// Creates a structured failure.
  AudioFailure({
    required this.code,
    required this.stage,
    required this.message,
    this.providerId,
    this.retryable = false,
    this.safeCause,
  }) {
    if (code.trim().isEmpty) {
      throw ArgumentError.value(code, 'code', 'Must not be empty.');
    }
    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message', 'Must not be empty.');
    }
    if (providerId != null && providerId!.trim().isEmpty) {
      throw ArgumentError.value(providerId, 'providerId', 'Must not be empty.');
    }
  }

  /// Stable machine-readable code.
  final String code;

  /// Pipeline stage where the failure originated.
  final AudioFailureStage stage;

  /// Message safe to log or show to a user.
  final String message;

  /// Stable provider ID when the failure originated in an adapter.
  final String? providerId;

  /// Whether retrying the operation may succeed.
  final bool retryable;

  /// Sanitized diagnostic cause. It must not contain credentials or payloads.
  final String? safeCause;

  @override
  String toString() {
    final provider = providerId == null ? '' : ', providerId: $providerId';
    final cause = safeCause == null ? '' : ', cause: $safeCause';
    return 'AudioFailure(code: $code, stage: ${stage.name}$provider, '
        'retryable: $retryable, message: $message$cause)';
  }
}
