/// Safe failure surfaced by voice orchestration.
final class VoiceFailure implements Exception {
  const VoiceFailure({
    required this.code,
    required this.stage,
    required this.message,
    this.providerId,
    this.retryable = false,
    this.safeCause,
  });

  /// Stable machine-readable code.
  final String code;

  /// Stable stage such as `input`, `backend`, `synthesis`, or `lifecycle`.
  final String stage;

  /// Message safe to show to an end user.
  final String message;

  /// Stable provider ID when the failure came from an adapter.
  final String? providerId;

  /// Whether retrying may succeed.
  final bool retryable;

  /// Sanitized diagnostic cause without credentials or provider payloads.
  final String? safeCause;

  @override
  String toString() {
    final provider = providerId == null ? '' : ', providerId: $providerId';
    final cause = safeCause == null ? '' : ', cause: $safeCause';
    return 'VoiceFailure(code: $code, stage: $stage$provider, '
        'retryable: $retryable, message: $message$cause)';
  }
}

/// Maps arbitrary implementation errors to safe voice failures.
abstract interface class VoiceFailureMapper {
  /// Converts [error] without exposing secrets or provider payloads.
  VoiceFailure map(
    Object error,
    StackTrace stackTrace, {
    required String stage,
  });
}

/// Conservative default mapper for applications without custom error policy.
final class DefaultVoiceFailureMapper implements VoiceFailureMapper {
  const DefaultVoiceFailureMapper();

  @override
  VoiceFailure map(
    Object error,
    StackTrace stackTrace, {
    required String stage,
  }) {
    if (error is VoiceFailure) {
      return error;
    }
    return VoiceFailure(
      code: 'voice_$stage',
      stage: stage,
      message: 'The voice operation could not be completed.',
      safeCause: error.runtimeType.toString(),
    );
  }
}
