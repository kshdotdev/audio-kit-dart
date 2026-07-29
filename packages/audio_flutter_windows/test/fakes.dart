import 'package:audio_flutter_windows/src/channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// One recorded invocation on the fake method channel.
final class FakeCall {
  const FakeCall(this.method, this.arguments);

  final String method;
  final Object? arguments;
}

/// Stands in for the native plugin: records every method call, replies from a
/// scripted table, and pushes session events on demand.
final class FakeWindowsChannel {
  final List<FakeCall> calls = <FakeCall>[];

  /// Reply payload per method name. A method with no entry replies `null`.
  final Map<String, Object?> replies = <String, Object?>{};

  /// Errors to raise instead of replying, per method name.
  final Map<String, PlatformException> errors = <String, PlatformException>{};

  MockStreamHandler? _streamHandler;
  MockStreamHandlerEventSink? _sink;

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    _messenger.setMockMethodCallHandler(
      const MethodChannel(kWindowsMethodChannel),
      (MethodCall call) async {
        calls.add(FakeCall(call.method, call.arguments));
        final PlatformException? error = errors[call.method];
        if (error != null) {
          throw error;
        }
        return replies[call.method];
      },
    );

    _streamHandler = MockStreamHandler.inline(
      onListen: (Object? arguments, MockStreamHandlerEventSink events) {
        _sink = events;
      },
      onCancel: (Object? arguments) {
        _sink = null;
      },
    );
    _messenger.setMockStreamHandler(
      const EventChannel(kWindowsEventChannel),
      _streamHandler,
    );
  }

  void remove() {
    _messenger.setMockMethodCallHandler(
      const MethodChannel(kWindowsMethodChannel),
      null,
    );
    _messenger.setMockStreamHandler(
      const EventChannel(kWindowsEventChannel),
      null,
    );
    _sink = null;
  }

  /// Pushes one session event to whoever is listening.
  void emitEvent(Map<Object?, Object?> event) => _sink?.success(event);
}
