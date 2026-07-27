import 'dart:async';

import 'descriptors.dart';
import 'failure.dart';
import 'provider.dart';

/// Runtime registry for replaceable speech providers.
final class SpeechProviderRegistry {
  final Map<String, SpeechProvider> _providers = <String, SpeechProvider>{};
  bool _closed = false;

  /// All registered providers in registration order.
  Iterable<SpeechProvider> get providers =>
      List<SpeechProvider>.unmodifiable(_providers.values);

  /// Registers [provider].
  ///
  /// Throws if the ID is already registered or the registry is closed.
  void register(SpeechProvider provider) {
    _ensureOpen();
    final id = provider.descriptor.id;
    if (_providers.containsKey(id)) {
      throw StateError('Speech provider "$id" is already registered.');
    }
    _providers[id] = provider;
  }

  /// Removes and returns the provider with [id], without closing it.
  SpeechProvider? unregister(String id) {
    _ensureOpen();
    return _providers.remove(id);
  }

  /// Finds a provider by its stable ID.
  SpeechProvider? operator [](String id) => _providers[id];

  /// Finds [T] by stable provider ID.
  T? find<T extends SpeechProvider>(String id) {
    final provider = _providers[id];
    return provider is T ? provider : null;
  }

  /// Returns providers implementing [T] and advertising [capability].
  Iterable<T> supporting<T extends SpeechProvider>(
    SpeechCapability capability,
  ) sync* {
    for (final provider in _providers.values) {
      if (provider is T && provider.descriptor.supports(capability)) {
        yield provider;
      }
    }
  }

  /// Closes all registered providers and then the registry.
  ///
  /// Every provider is given a chance to close even if another provider fails.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final failures = <SpeechFailure>[];
    for (final MapEntry(key: providerId, value: provider)
        in _providers.entries) {
      try {
        await provider.close();
      } catch (error) {
        failures.add(
          SpeechFailure(
            code: 'provider_close_failed',
            stage: 'shutdown',
            providerId: providerId,
            safeMessage: 'A speech provider could not be closed.',
            safeCause: error.runtimeType.toString(),
          ),
        );
      }
    }
    _providers.clear();
    if (failures.isNotEmpty) {
      throw SpeechProviderCloseFailure(
        List<SpeechFailure>.unmodifiable(failures),
      );
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Speech provider registry is closed.');
    }
  }
}

/// Aggregates failures encountered while closing a registry.
final class SpeechProviderCloseFailure implements Exception {
  const SpeechProviderCloseFailure(this.failures);

  /// Provider close failures in registration order.
  final List<SpeechFailure> failures;

  @override
  String toString() =>
      'SpeechProviderCloseFailure(${failures.length} provider(s) failed)';
}
