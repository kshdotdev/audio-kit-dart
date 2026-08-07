import 'dart:ffi';

import 'bindings.dart';
import 'processor.dart' show kSupportedAecSampleRates;
import 'runtime_binding_resolver.dart';

/// Result of probing the native AEC3 runtime for one concrete audio format.
///
/// [isAvailable] is true only after the library loaded, all expected symbols
/// resolved, `aec_create` returned a non-null handle, and that temporary handle
/// was destroyed again. Merely finding a library or reading its version is not
/// sufficient.
final class AecRuntimeCapability {
  const AecRuntimeCapability.available({this.version})
    : isAvailable = true,
      failure = null;

  const AecRuntimeCapability.unavailable(this.failure)
    : isAvailable = false,
      version = null;

  /// Whether a native engine can be created for the probed format.
  final bool isAvailable;

  /// Native engine version, when the ABI exposes one.
  final String? version;

  /// Structured loading or creation failure when unavailable.
  final AecUnavailable? failure;
}

/// Probes the same packaged/path runtime resolution used by
/// `AecProcessor.create`.
///
/// This function never retains a native engine. It creates one temporary
/// handle for [sampleRate]/[channels] and destroys it before returning. Invalid
/// format arguments remain programmer errors and throw [ArgumentError]; native
/// loading, symbol, creation, version, and destruction failures are represented
/// by an unavailable result.
AecRuntimeCapability probeAecRuntime({
  String? libraryPath,
  int sampleRate = 16000,
  int channels = 1,
}) {
  _validateProbeFormat(sampleRate: sampleRate, channels: channels);
  try {
    return probeAecBindings(
      resolveAecRuntimeBindings(libraryPath: libraryPath),
      sampleRate: sampleRate,
      channels: channels,
    );
  } on AecUnavailable catch (error) {
    return AecRuntimeCapability.unavailable(error);
  } on Object catch (error) {
    return AecRuntimeCapability.unavailable(
      AecUnavailable(
        'The native echo-cancellation runtime could not be resolved.',
        cause: error.toString(),
      ),
    );
  }
}

/// Probes already-resolved [bindings], primarily for embedders and tests.
///
/// The handle returned by [AecBindings.create] is destroyed exactly once before
/// this function returns, including when reading the version fails. A null
/// handle is an honest unavailable result and is never passed to `destroy`.
AecRuntimeCapability probeAecBindings(
  AecBindings bindings, {
  int sampleRate = 16000,
  int channels = 1,
}) {
  _validateProbeFormat(sampleRate: sampleRate, channels: channels);

  Pointer<Void> handle;
  try {
    handle = bindings.create(sampleRate, channels);
  } on Object catch (error) {
    return AecRuntimeCapability.unavailable(
      AecUnavailable(
        'aec_create threw while probing the native runtime.',
        cause: error.toString(),
      ),
    );
  }
  if (handle == nullptr) {
    return AecRuntimeCapability.unavailable(
      AecUnavailable(
        'aec_create returned null while probing '
        '(sampleRate: $sampleRate, channels: $channels).',
      ),
    );
  }

  String? version;
  Object? versionFailure;
  Object? destroyFailure;
  try {
    version = bindings.version();
  } on Object catch (error) {
    versionFailure = error;
  }
  try {
    bindings.destroy(handle);
  } on Object catch (error) {
    destroyFailure = error;
  }

  if (versionFailure != null || destroyFailure != null) {
    final causes = <String>[
      if (versionFailure != null) 'version: $versionFailure',
      if (destroyFailure != null) 'destroy: $destroyFailure',
    ];
    return AecRuntimeCapability.unavailable(
      AecUnavailable(
        'The native runtime could create an engine but did not complete a '
        'safe capability probe.',
        cause: causes.join('; '),
      ),
    );
  }
  return AecRuntimeCapability.available(version: version);
}

void _validateProbeFormat({required int sampleRate, required int channels}) {
  if (!kSupportedAecSampleRates.contains(sampleRate)) {
    throw ArgumentError.value(
      sampleRate,
      'sampleRate',
      'WebRTC AudioProcessing supports only ${kSupportedAecSampleRates.join(', ')} Hz.',
    );
  }
  if (channels != 1) {
    throw ArgumentError.value(
      channels,
      'channels',
      'Only mono AEC probing is supported.',
    );
  }
}
