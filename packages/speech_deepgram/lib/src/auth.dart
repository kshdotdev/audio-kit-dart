import 'package:audio_core/audio_core.dart';

/// Authorization mechanism accepted by Deepgram's websocket handshake.
enum DeepgramAuthorizationScheme {
  /// Long-lived Deepgram project API key.
  token('Token'),

  /// Short-lived JWT issued by Deepgram's token API.
  bearer('Bearer');

  const DeepgramAuthorizationScheme(this.headerScheme);

  /// Scheme written before the credential.
  final String headerScheme;
}

/// A short-lived Deepgram credential.
///
/// The token value is deliberately omitted from [toString].
final class DeepgramAccessToken {
  const DeepgramAccessToken({
    required this.value,
    this.expiresAt,
    this.authorizationScheme = DeepgramAuthorizationScheme.token,
  });

  /// Credential sent in the Deepgram authorization header.
  final String value;

  /// Optional wall-clock expiry supplied by the token issuer.
  final DateTime? expiresAt;

  /// Header scheme appropriate for an API key or temporary JWT.
  final DeepgramAuthorizationScheme authorizationScheme;

  /// Whether the token is already expired, allowing a small clock-skew margin.
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
      'DeepgramAccessToken(expiresAt: $expiresAt, '
      'authorizationScheme: ${authorizationScheme.name}, value: <redacted>)';
}

/// Renewable credential source used for every new recognition session.
abstract interface class DeepgramTokenSource {
  /// Returns a currently usable token.
  Future<DeepgramAccessToken> getToken({
    AudioCancellationToken? cancellationToken,
  });
}

/// Fixed credential source for local development and tests.
///
/// Production applications should prefer a renewable server-issued token.
final class StaticDeepgramTokenSource implements DeepgramTokenSource {
  const StaticDeepgramTokenSource(this._token);

  final DeepgramAccessToken _token;

  @override
  Future<DeepgramAccessToken> getToken({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return _token;
  }
}
