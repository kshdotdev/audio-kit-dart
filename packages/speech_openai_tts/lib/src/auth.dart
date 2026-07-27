import 'package:audio_core/audio_core.dart';

/// A short-lived OpenAI API credential.
///
/// The credential is deliberately omitted from [toString].
final class OpenAiAccessToken {
  const OpenAiAccessToken({required this.value, this.expiresAt});

  /// Credential sent in the OpenAI authorization header.
  final String value;

  /// Optional wall-clock expiry supplied by the token issuer.
  final DateTime? expiresAt;

  /// Whether the credential is already expired, allowing for clock skew.
  bool isExpired({
    DateTime? now,
    Duration clockSkew = const Duration(seconds: 30),
  }) {
    final DateTime? expiry = expiresAt;
    return expiry != null &&
        !expiry.isAfter((now ?? DateTime.now().toUtc()).add(clockSkew));
  }

  @override
  String toString() =>
      'OpenAiAccessToken(expiresAt: $expiresAt, value: <redacted>)';
}

/// Renewable credential source queried for every new synthesis request.
abstract interface class OpenAiTokenSource {
  /// Returns a currently usable access token.
  Future<OpenAiAccessToken> getToken({
    AudioCancellationToken? cancellationToken,
  });
}

/// Fixed credential source for local development and tests.
///
/// Production applications should normally inject renewable, scoped tokens.
final class StaticOpenAiTokenSource implements OpenAiTokenSource {
  const StaticOpenAiTokenSource(this._token);

  final OpenAiAccessToken _token;

  @override
  Future<OpenAiAccessToken> getToken({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return _token;
  }
}
