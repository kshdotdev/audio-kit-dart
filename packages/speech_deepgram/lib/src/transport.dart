import 'dart:typed_data';

/// Immutable websocket connection request.
final class DeepgramTransportRequest {
  DeepgramTransportRequest({
    required this.uri,
    required this.authorization,
    required this.pingInterval,
    required this.closeTimeout,
  }) {
    if (authorization.trim().isEmpty) {
      throw ArgumentError.value(
        authorization,
        'authorization',
        'Must not be empty.',
      );
    }
  }

  /// Fully parameterized Deepgram listen endpoint.
  final Uri uri;

  /// Authorization header value.
  final String authorization;

  /// Websocket ping cadence.
  final Duration pingInterval;

  /// Graceful close timeout.
  final Duration closeTimeout;

  @override
  String toString() =>
      'DeepgramTransportRequest(uri: $uri, authorization: <redacted>)';
}

/// Base type for messages received from a Deepgram transport.
sealed class DeepgramTransportEvent {
  const DeepgramTransportEvent();
}

/// UTF-8 JSON response from Deepgram.
final class DeepgramTransportText extends DeepgramTransportEvent {
  const DeepgramTransportText(this.text);

  /// Unmodified response text.
  final String text;
}

/// The remote websocket closed.
final class DeepgramTransportClosed extends DeepgramTransportEvent {
  const DeepgramTransportClosed({this.code, this.reason});

  /// Websocket close code, when available.
  final int? code;

  /// Non-sensitive close reason, when available.
  final String? reason;
}

/// The transport encountered a connection or protocol error.
final class DeepgramTransportError extends DeepgramTransportEvent {
  const DeepgramTransportError(this.error, [this.stackTrace]);

  /// Original error for adapter diagnostics.
  final Object error;

  /// Original stack trace.
  final StackTrace? stackTrace;
}

/// One connected, caller-owned Deepgram stream.
abstract interface class DeepgramStreamingTransport {
  /// Typed incoming transport events.
  Stream<DeepgramTransportEvent> get events;

  /// Sends one encoded linear-PCM audio block.
  Future<void> sendAudio(Uint8List bytes);

  /// Requests final recognition and a graceful remote close.
  Future<void> finish();

  /// Immediately interrupts pending network work.
  Future<void> abort();

  /// Releases resources. This operation must be idempotent.
  Future<void> close();
}

/// Injectable transport factory. Tests can provide an in-memory transport.
abstract interface class DeepgramTransportFactory {
  /// Connects a single recognition stream.
  Future<DeepgramStreamingTransport> connect(DeepgramTransportRequest request);
}
