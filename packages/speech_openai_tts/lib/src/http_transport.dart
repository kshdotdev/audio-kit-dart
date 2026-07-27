import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_core/audio_core.dart';
import 'package:http/http.dart' as http;

import 'options.dart';
import 'transport.dart';

/// Default package:http implementation with one cancellable client per call.
final class HttpOpenAiTtsTransport implements OpenAiTtsTransport {
  HttpOpenAiTtsTransport({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;
  final Set<_HttpOpenAiTtsOperation> _operations = <_HttpOpenAiTtsOperation>{};
  Future<void>? _closeFuture;
  bool _closed = false;

  @override
  Future<OpenAiTtsTransportOperation> start(
    OpenAiTtsTransportRequest request, {
    AudioCancellationToken? cancellationToken,
  }) async {
    if (_closed) {
      throw StateError('OpenAI transport is closed.');
    }
    cancellationToken?.throwIfCancelled();
    late final _HttpOpenAiTtsOperation operation;
    operation = _HttpOpenAiTtsOperation(
      _clientFactory(),
      request,
      () => _operations.remove(operation),
    );
    _operations.add(operation);
    if (cancellationToken != null) {
      unawaited(
        cancellationToken.whenCancelled
            .then<void>((_) => operation.abort())
            .catchError((Object _) {
              // The operation's consumer observes transport cleanup failures.
            }),
      );
    }
    return operation;
  }

  @override
  Future<void> close() => _closeFuture ??= _doClose();

  Future<void> _doClose() async {
    _closed = true;
    final List<_HttpOpenAiTtsOperation> operations =
        List<_HttpOpenAiTtsOperation>.of(_operations);
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      for (final _HttpOpenAiTtsOperation operation in operations) {
        try {
          await operation.close();
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
      }
    } finally {
      _operations.clear();
    }
    if (firstError case final Object error) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}

final class _HttpOpenAiTtsOperation implements OpenAiTtsTransportOperation {
  _HttpOpenAiTtsOperation(this._client, this._request, this._onClosed) {
    _response = _send();
  }

  final http.Client _client;
  final OpenAiTtsTransportRequest _request;
  final void Function() _onClosed;
  late final Future<OpenAiTtsTransportResponse> _response;
  Future<void>? _closeFuture;

  @override
  Future<OpenAiTtsTransportResponse> get response => _response;

  Future<OpenAiTtsTransportResponse> _send() async {
    final http.Request request = http.Request('POST', _request.endpoint)
      ..headers.addAll(<String, String>{
        'Authorization': _request.authorization,
        'Content-Type': 'application/json',
        'Accept': _request.responseFormat == OpenAiTtsResponseFormat.wav
            ? 'audio/wav'
            : 'application/octet-stream',
      })
      ..body = jsonEncode(<String, Object>{
        'model': _request.modelId,
        'voice': _request.voiceId.startsWith('voice_')
            ? <String, String>{'id': _request.voiceId}
            : _request.voiceId,
        'input': _request.text,
        'speed': _request.speed,
        'response_format': _request.responseFormat.wireName,
        if (_request.instructions case final String instructions)
          'instructions': instructions,
      });
    final http.StreamedResponse response = await _client.send(request);
    final int? contentLength = response.contentLength;
    if (contentLength != null &&
        contentLength > _request.maximumResponseBytes) {
      throw StateError('OpenAI speech response exceeds the configured bound.');
    }
    return OpenAiTtsTransportResponse(
      statusCode: response.statusCode,
      body: _boundedBody(response.stream, _request.maximumResponseBytes),
      contentLength: contentLength,
      contentType: response.headers['content-type'],
      requestId: response.headers['x-request-id'],
      retryAfter: _parseRetryAfter(response.headers['retry-after']),
    );
  }

  @override
  Future<void> abort() => close();

  @override
  Future<void> close() => _closeFuture ??= _doClose();

  Future<void> _doClose() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      _client.close();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    } finally {
      _onClosed();
    }
    if (firstError case final Object error) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}

Stream<Uint8List> _boundedBody(
  Stream<List<int>> source,
  int maximumResponseBytes,
) async* {
  var receivedBytes = 0;
  await for (final List<int> chunk in source) {
    if (chunk.isEmpty) {
      continue;
    }
    if (chunk.length > maximumResponseBytes - receivedBytes) {
      throw StateError('OpenAI speech response exceeds the configured bound.');
    }
    receivedBytes += chunk.length;
    yield Uint8List.fromList(chunk);
  }
}

Duration? _parseRetryAfter(String? value) {
  if (value == null) {
    return null;
  }
  final int? seconds = int.tryParse(value);
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}
