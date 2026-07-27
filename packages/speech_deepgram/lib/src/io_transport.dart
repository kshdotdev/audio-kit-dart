import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as websocket_status;

import 'transport.dart';

/// VM websocket implementation used by default.
final class IoDeepgramTransportFactory implements DeepgramTransportFactory {
  const IoDeepgramTransportFactory();

  @override
  Future<DeepgramStreamingTransport> connect(
    DeepgramTransportRequest request,
  ) async {
    // Ownership is transferred to _IoDeepgramStreamingTransport below.
    // ignore: close_sinks
    final WebSocket socket = await WebSocket.connect(
      request.uri.toString(),
      headers: <String, String>{'Authorization': request.authorization},
    ).timeout(request.closeTimeout);
    socket.pingInterval = request.pingInterval;
    final IOWebSocketChannel channel = IOWebSocketChannel(socket);
    return _IoDeepgramStreamingTransport(
      channel: channel,
      socket: socket,
      closeTimeout: request.closeTimeout,
    );
  }
}

final class _IoDeepgramStreamingTransport
    implements DeepgramStreamingTransport {
  _IoDeepgramStreamingTransport({
    required this._channel,
    required this._socket,
    required this.closeTimeout,
  }) {
    _subscription = _channel.stream.listen(
      _onData,
      onError: (Object error, StackTrace stackTrace) {
        if (!_events.isClosed) {
          _events.add(DeepgramTransportError(error, stackTrace));
        }
      },
      onDone: _onDone,
    );
  }

  final IOWebSocketChannel _channel;
  final WebSocket _socket;
  final Duration closeTimeout;
  final StreamController<DeepgramTransportEvent> _events =
      StreamController<DeepgramTransportEvent>.broadcast();
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<Object?> _subscription;
  Future<void>? _closeFuture;
  bool _finishing = false;

  @override
  Stream<DeepgramTransportEvent> get events => _events.stream;

  @override
  Future<void> sendAudio(Uint8List bytes) async {
    if (_closeFuture != null || _finishing) {
      throw StateError('Deepgram transport is no longer accepting audio.');
    }
    // Unlike WebSocket.add(), addStream propagates the socket consumer's pause
    // signal. Completion therefore means this block crossed the SDK's bounded
    // user-space write path instead of merely entering an unbounded sink.
    await _socket.addStream(Stream<List<int>>.value(bytes));
  }

  @override
  Future<void> finish() async {
    if (_closeFuture != null || _finishing) {
      return;
    }
    _finishing = true;
    await _socket.addStream(
      Stream<Object>.fromIterable(const <Object>[
        '{"type":"Finalize"}',
        '{"type":"CloseStream"}',
      ]),
    );
    try {
      await _done.future.timeout(closeTimeout);
    } on TimeoutException {
      await _socket.close(websocket_status.normalClosure, 'Close timeout');
    }
  }

  @override
  Future<void> abort() =>
      _close(code: websocket_status.normalClosure, reason: 'Cancelled');

  @override
  Future<void> close() =>
      _close(code: websocket_status.normalClosure, reason: 'Closed');

  Future<void> _close({required int code, required String reason}) =>
      _closeFuture ??= _doClose(code: code, reason: reason);

  Future<void> _doClose({required int code, required String reason}) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _socket.close(code, reason);
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await _subscription.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }

  void _onData(Object? data) {
    if (_events.isClosed) {
      return;
    }
    if (data case final String text) {
      _events.add(DeepgramTransportText(text));
    }
  }

  void _onDone() {
    if (!_events.isClosed) {
      _events.add(
        DeepgramTransportClosed(
          code: _channel.closeCode,
          reason: _channel.closeReason,
        ),
      );
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}
