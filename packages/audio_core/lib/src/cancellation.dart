import 'dart:async';

/// Synchronous observer invoked when audio cancellation is requested.
typedef AudioCancellationListener =
    void Function(AudioCancellation cancellation);

/// Immutable reason for cooperative audio-operation cancellation.
final class AudioCancellation {
  /// Creates a cancellation reason.
  const AudioCancellation({this.reason = 'cancelled'});

  /// Stable machine-readable reason.
  final String reason;
}

/// Read-only cooperative cancellation signal.
final class AudioCancellationToken {
  AudioCancellationToken._(this._controller);

  final AudioCancellationController _controller;

  /// Whether cancellation has been requested.
  bool get isCancelled => _controller.isCancelled;

  /// Current cancellation, or `null` while active.
  AudioCancellation? get cancellation => _controller.cancellation;

  /// Completes exactly once when cancellation is requested.
  Future<AudioCancellation> get whenCancelled => _controller._completion.future;

  /// Registers a disposable synchronous cancellation observer.
  ///
  /// Unlike awaiting [whenCancelled], disposing the returned registration
  /// releases the callback and everything it captures before this token is
  /// cancelled. This is important for short operations that share a long-lived
  /// session token.
  ///
  /// Listener failures are isolated so cancellation remains a no-throw signal.
  ///
  /// When cancellation was already requested, [listener] runs immediately and
  /// the returned registration is already disposed.
  AudioCancellationRegistration register(AudioCancellationListener listener) =>
      _controller._register(listener);

  /// Throws [AudioCancelledException] after cancellation.
  void throwIfCancelled() {
    final value = cancellation;
    if (value != null) {
      throw AudioCancelledException(value);
    }
  }
}

/// Disposable observer returned by [AudioCancellationToken.register].
final class AudioCancellationRegistration {
  AudioCancellationRegistration._(this._dispose);

  AudioCancellationRegistration._disposed() : _dispose = null;

  void Function()? _dispose;

  /// Whether this observer no longer retains its callback.
  bool get isDisposed => _dispose == null;

  /// Unregisters the observer. Repeated calls have no effect.
  void dispose() {
    final void Function()? disposeCallback = _dispose;
    _dispose = null;
    disposeCallback?.call();
  }

  void _deactivate() {
    _dispose = null;
  }
}

/// Owns an [AudioCancellationToken] and can cancel it once.
final class AudioCancellationController {
  /// Creates an active cancellation controller.
  AudioCancellationController() : _completion = Completer<AudioCancellation>() {
    token = AudioCancellationToken._(this);
  }

  final Completer<AudioCancellation> _completion;
  final Map<int, _AudioCancellationListenerEntry> _listeners =
      <int, _AudioCancellationListenerEntry>{};
  var _nextListenerId = 0;

  /// Signal shared with an operation.
  late final AudioCancellationToken token;

  /// Current cancellation, or `null` while active.
  AudioCancellation? cancellation;

  /// Whether [cancel] has been called.
  bool get isCancelled => _completion.isCompleted;

  /// Number of active disposable observers.
  ///
  /// This is primarily useful for lifecycle diagnostics and tests.
  int get activeRegistrationCount => _listeners.length;

  /// Requests cancellation. Repeated calls have no effect.
  void cancel([AudioCancellation value = const AudioCancellation()]) {
    if (_completion.isCompleted) {
      return;
    }
    cancellation = value;
    _completion.complete(value);
    final List<_AudioCancellationListenerEntry> listeners =
        List<_AudioCancellationListenerEntry>.of(_listeners.values);
    _listeners.clear();
    for (final _AudioCancellationListenerEntry entry in listeners) {
      entry.registration._deactivate();
      try {
        entry.listener(value);
      } on Object {
        // Cancellation is a no-throw signal. One faulty observer must not
        // prevent cancellation state or other independent observers.
      }
    }
  }

  AudioCancellationRegistration _register(AudioCancellationListener listener) {
    final AudioCancellation? current = cancellation;
    if (current != null) {
      try {
        listener(current);
      } on Object {
        // Already-cancelled registration follows the same failure-isolation
        // rule as observers present when cancel() was called.
      }
      return AudioCancellationRegistration._disposed();
    }
    final int id = _nextListenerId++;
    late final AudioCancellationRegistration registration;
    registration = AudioCancellationRegistration._(() {
      _listeners.remove(id);
    });
    _listeners[id] = _AudioCancellationListenerEntry(
      listener: listener,
      registration: registration,
    );
    return registration;
  }
}

final class _AudioCancellationListenerEntry {
  const _AudioCancellationListenerEntry({
    required this.listener,
    required this.registration,
  });

  final AudioCancellationListener listener;
  final AudioCancellationRegistration registration;
}

/// Thrown when a cooperative operation observes cancellation.
final class AudioCancelledException implements Exception {
  /// Creates a cancellation exception.
  const AudioCancelledException(this.cancellation);

  /// Cancellation that stopped the operation.
  final AudioCancellation cancellation;

  @override
  String toString() =>
      'AudioCancelledException(reason: ${cancellation.reason})';
}
