// [AecBindings] over a build-hook-registered *code asset*, rather than over a
// [DynamicLibrary] opened from a path.
//
// These are two genuinely different resolution mechanisms and the package needs
// both. `DynamicLibrary.open` takes a filesystem path; a code asset registered
// by `hook/build.dart` has no stable path a consumer could name — the SDK
// copies it next to the build output and rewrites its install name. It is
// addressed by *asset id* instead, and only `@Native` external functions can do
// that. Verified on Dart 3.12.0: `DynamicLibrary.open('package:audio_aec/...')`
// does not resolve an asset id, it is treated as a literal file name and fails.
// See doc/DISTRIBUTION.md.
//
// The asset id below must stay in lockstep with the `name:` the hook passes to
// `CodeAsset` (`src/native_asset_bindings.dart`). There is no compile-time link
// between the two — a mismatch surfaces only as [available] returning false.

@DefaultAsset('package:audio_aec/src/native_asset_bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// [AecBindings] backed by the code asset a build hook registered.
///
/// Construct through [tryResolve] rather than directly: whether the asset
/// exists is not knowable until a symbol is actually called, so a bare
/// constructor would hand back an instance that throws on first use.
final class NativeAssetAecBindings implements AecBindings {
  const NativeAssetAecBindings._();

  /// Returns bindings when a code asset is bundled, `null` when none is.
  ///
  /// The probe is a real call to `aec_version`, because that is the only way to
  /// ask. Asset resolution is lazy and per-symbol: nothing fails at import
  /// time, and an absent asset surfaces as an [ArgumentError] from
  /// `Native._ffi_resolver_function` on the first invocation. Any error is
  /// treated as "not available" — the caller has a working fallback, and a
  /// probe that threw would defeat the point of probing.
  static NativeAssetAecBindings? tryResolve() {
    try {
      final Pointer<Utf8> version = _version();
      if (version == nullptr) {
        return null;
      }
      // Reading the string proves the pointer is real rather than a resolver
      // artefact, and costs one strlen once per process.
      version.toDartString();
      return const NativeAssetAecBindings._();
    } on Object {
      return null;
    }
  }

  /// Whether a code asset is bundled for this package.
  static bool get available => tryResolve() != null;

  @override
  Pointer<Void> create(int sampleRateHz, int numChannels) =>
      _create(sampleRateHz, numChannels);

  @override
  void processReverse(Pointer<Void> handle, Pointer<Int16> ref, int frames) =>
      _processReverse(handle, ref, frames);

  @override
  void processCapture(
    Pointer<Void> handle,
    Pointer<Int16> cap,
    Pointer<Int16> out,
    int frames,
    int streamDelayMs,
  ) => _processCapture(handle, cap, out, frames, streamDelayMs);

  @override
  void getMetrics(
    Pointer<Void> handle,
    Pointer<Double> erl,
    Pointer<Double> erle,
    Pointer<Double> residual,
    Pointer<Int32> delayMs,
  ) => _getMetrics(handle, erl, erle, residual, delayMs);

  @override
  void destroy(Pointer<Void> handle) => _destroy(handle);

  @override
  String? version() {
    final Pointer<Utf8> pointer = _version();
    return pointer == nullptr ? null : pointer.toDartString();
  }
}

// The same six symbols FfiAecBindings looks up by name, declared statically so
// the asset id can be attached. `isLeaf` matches the DynamicLibrary path: these
// four neither call back into Dart nor block.

@Native<Pointer<Void> Function(Int32, Int32)>(symbol: 'aec_create')
external Pointer<Void> _create(int sampleRateHz, int numChannels);

@Native<Void Function(Pointer<Void>, Pointer<Int16>, Int32)>(
  symbol: 'aec_process_reverse',
  isLeaf: true,
)
external void _processReverse(
  Pointer<Void> handle,
  Pointer<Int16> ref,
  int frames,
);

@Native<
  Void Function(Pointer<Void>, Pointer<Int16>, Pointer<Int16>, Int32, Int32)
>(symbol: 'aec_process_capture', isLeaf: true)
external void _processCapture(
  Pointer<Void> handle,
  Pointer<Int16> cap,
  Pointer<Int16> out,
  int frames,
  int streamDelayMs,
);

@Native<
  Void Function(
    Pointer<Void>,
    Pointer<Double>,
    Pointer<Double>,
    Pointer<Double>,
    Pointer<Int32>,
  )
>(symbol: 'aec_get_metrics', isLeaf: true)
external void _getMetrics(
  Pointer<Void> handle,
  Pointer<Double> erl,
  Pointer<Double> erle,
  Pointer<Double> residual,
  Pointer<Int32> delayMs,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'aec_destroy')
external void _destroy(Pointer<Void> handle);

@Native<Pointer<Utf8> Function()>(symbol: 'aec_version')
external Pointer<Utf8> _version();
