import 'dart:async';

import 'descriptors.dart';

/// Base contract implemented by every speech provider adapter.
abstract interface class SpeechProvider {
  /// Static provider metadata and capabilities.
  SpeechProviderDescriptor get descriptor;

  /// Releases provider resources. Implementations must be idempotent.
  Future<void> close();
}

/// Base class that makes provider cleanup deterministic and idempotent.
abstract base class IdempotentSpeechProvider implements SpeechProvider {
  Future<void>? _closeFuture;

  /// Whether [close] has been requested.
  bool get isClosed => _closeFuture != null;

  @override
  Future<void> close() => _closeFuture ??= onClose();

  /// Performs provider-specific cleanup exactly once.
  Future<void> onClose();

  /// Throws when an operation is attempted after [close].
  void ensureOpen() {
    if (isClosed) {
      throw StateError('Speech provider is closed.');
    }
  }
}
