import 'validation.dart';

/// Failure raised by provider-neutral speech operations.
final class SpeechFailure implements Exception {
  SpeechFailure({
    required this.code,
    required this.stage,
    required this.safeMessage,
    this.providerId,
    this.retryable = false,
    this.safeCause,
  }) {
    requireStableIdentifier(code, 'code');
    requireStableIdentifier(stage, 'stage');
    requireOptionalNonEmpty(providerId, 'providerId');
    requireNonEmpty(safeMessage, 'safeMessage');
    requireOptionalNonEmpty(safeCause, 'safeCause');
  }

  /// Stable machine-readable failure code.
  final String code;

  /// Stable pipeline stage, such as `prepare`, `recognition`, or `synthesis`.
  final String stage;

  /// Provider ID when a provider was involved.
  final String? providerId;

  /// Whether retrying the operation may succeed.
  final bool retryable;

  /// Message safe to show to an end user.
  final String safeMessage;

  /// Sanitized diagnostic cause without credentials or provider payloads.
  final String? safeCause;

  @override
  String toString() {
    final provider = providerId == null ? '' : ', providerId: $providerId';
    final cause = safeCause == null ? '' : ', cause: $safeCause';
    return 'SpeechFailure(code: $code, stage: $stage$provider, '
        'retryable: $retryable, message: $safeMessage$cause)';
  }
}
