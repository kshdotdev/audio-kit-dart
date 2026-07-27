import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';

import 'options.dart';

/// Typed request sent through an [OpenAiTtsTransport].
final class OpenAiTtsTransportRequest {
  OpenAiTtsTransportRequest({
    required this.endpoint,
    required this.authorization,
    required this.modelId,
    required this.voiceId,
    required this.text,
    required this.speed,
    required this.responseFormat,
    required this.maximumResponseBytes,
    this.instructions,
  }) {
    if (authorization.trim().isEmpty ||
        modelId.trim().isEmpty ||
        voiceId.trim().isEmpty ||
        text.trim().isEmpty) {
      throw ArgumentError(
        'Authorization, model, voice, and text are required.',
      );
    }
    if (maximumResponseBytes < 1) {
      throw ArgumentError.value(
        maximumResponseBytes,
        'maximumResponseBytes',
        'Must be positive.',
      );
    }
  }

  /// OpenAI speech endpoint.
  final Uri endpoint;

  /// Authorization header value.
  final String authorization;

  /// OpenAI model identifier.
  final String modelId;

  /// OpenAI voice identifier.
  final String voiceId;

  /// Input text.
  final String text;

  /// Relative speaking speed.
  final double speed;

  /// Requested response encoding.
  final OpenAiTtsResponseFormat responseFormat;

  /// Optional model-specific instructions.
  final String? instructions;

  /// Hard bound for the response body.
  final int maximumResponseBytes;

  @override
  String toString() =>
      'OpenAiTtsTransportRequest(endpoint: $endpoint, modelId: $modelId, '
      'voiceId: $voiceId, responseFormat: ${responseFormat.wireName}, '
      'authorization: <redacted>, text: <redacted>)';
}

/// HTTP response metadata and its bounded, single-subscription byte stream.
final class OpenAiTtsTransportResponse {
  OpenAiTtsTransportResponse({
    required this.statusCode,
    required this.body,
    this.contentLength,
    this.contentType,
    this.requestId,
    this.retryAfter,
  });

  /// HTTP status code.
  final int statusCode;

  /// Bounded response body.
  ///
  /// Implementations complete the surrounding response as soon as headers are
  /// available. Chunks must be owned and the stream must be single-subscription.
  final Stream<Uint8List> body;

  /// Declared response length, when supplied.
  final int? contentLength;

  /// Response content type, when supplied.
  final String? contentType;

  /// Provider request identifier safe to use for support diagnostics.
  final String? requestId;

  /// Provider retry delay, when supplied.
  final Duration? retryAfter;
}

/// One independently cancellable HTTP synthesis operation.
abstract interface class OpenAiTtsTransportOperation {
  /// Completes after response headers arrive, before the body necessarily ends.
  Future<OpenAiTtsTransportResponse> get response;

  /// Interrupts pending I/O.
  Future<void> abort();

  /// Releases operation resources idempotently.
  Future<void> close();
}

/// Injectable OpenAI transport. Tests can provide an in-memory implementation.
abstract interface class OpenAiTtsTransport {
  /// Starts one independently cancellable request.
  Future<OpenAiTtsTransportOperation> start(
    OpenAiTtsTransportRequest request, {
    AudioCancellationToken? cancellationToken,
  });

  /// Aborts active operations and releases shared resources.
  Future<void> close();
}
