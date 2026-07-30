// Adapted from Control Center's `packages/cc_natives/lib/src/audio/aec/
// aec_ffi_bindings.dart` and `packages/cc_natives/lib/src/native_library.dart`.
// Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.
//
// Adaptation notes: Control Center resolves every native from an application
// support directory populated by out-of-band build scripts, which a published
// package cannot do (risk R4). The candidate policy here is therefore explicit
// path -> environment variable -> conventional locations beside the executable,
// and the failure is a structured [AecUnavailable] carrying the paths actually
// tried. The raw symbol surface is otherwise unchanged, because the C ABI is.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Environment variable consulted by [FfiAecBindings.open] when no explicit
/// path is supplied.
///
/// It must name the library file itself, not a directory.
const String aecLibraryEnvironmentVariable = 'AUDIO_AEC_LIBRARY';

/// Value a `double` metric carries when AEC3 has no measurement yet.
///
/// The native shim writes this sentinel rather than leaving the output
/// untouched, so the Dart side can map "no value" to `null` without a second
/// out-parameter per metric.
const double kAecMetricUnavailable = -1000.0;

/// Thrown when the native echo-cancellation library cannot be resolved, cannot
/// be loaded, does not export the expected symbols, or refuses to instantiate.
///
/// This is a broken or incomplete installation, not a runtime condition, so it
/// is raised rather than swallowed: silently degrading would record an
/// echo-laden track that looks fine until a transcript shows every remote line
/// twice. Callers that legitimately have no far-end reference — in-person
/// capture, or any single-source pipeline — should construct
/// `AecMicFilter.passthrough` instead of treating this as a fallback path.
final class AecUnavailable implements Exception {
  /// Creates a structured unavailability failure.
  const AecUnavailable(
    this.message, {
    this.attemptedPaths = const <String>[],
    this.cause,
  });

  /// What failed: resolution, loading, symbol lookup, or instantiation.
  final String message;

  /// Library paths tried, in the order they were tried.
  ///
  /// Empty when the failure happened after a library had already loaded.
  final List<String> attemptedPaths;

  /// Sanitized underlying error, when one was thrown.
  final String? cause;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('AecUnavailable: $message');
    if (attemptedPaths.isNotEmpty) {
      buffer.write('\n  Tried, in order:');
      for (final String path in attemptedPaths) {
        buffer.write('\n    - $path');
      }
    }
    if (cause != null) {
      buffer.write('\n  Cause: $cause');
    }
    buffer.write(
      '\n  audio_aec does not ship a binary: build one with '
      'packages/audio_aec/tool/build_native.sh and point '
      '$aecLibraryEnvironmentVariable at the result, or pass an explicit '
      'libraryPath. See the package README, "Native library (risk R4)".',
    );
    return buffer.toString();
  }
}

/// The six-symbol C ABI of the native echo canceller, as a Dart interface.
///
/// Everything above this seam — [AecProcessor], and the filter that composes
/// it — is written against this interface, so the whole stack is exercisable
/// with an in-Dart fake and no native library present. That matters more here
/// than in most FFI packages: the library is not distributed (risk R4), so a
/// test suite that required it would be a test suite nobody can run.
///
/// The interface is deliberately pointer-level rather than list-level. Keeping
/// [Pointer] in the signatures means [AecProcessor]'s real scratch-buffer
/// marshalling is the code under test, instead of a list-shaped shim that only
/// resembles it.
///
/// Blocks are mono PCM16 of `sampleRateHz / 100` samples — one 10 ms block, the
/// unit `AudioProcessing::GetFrameSize` defines and the only size the native
/// side accepts.
abstract interface class AecBindings {
  /// Creates a native instance, or returns [nullptr] on failure.
  Pointer<Void> create(int sampleRateHz, int numChannels);

  /// Feeds one far-end (loopback/render) block of [frames] samples.
  void processReverse(Pointer<Void> handle, Pointer<Int16> ref, int frames);

  /// Cleans one near-end (mic/capture) block: reads [cap], writes the
  /// echo-removed result into [out].
  ///
  /// [streamDelayMs] is the measured far-end→capture lead. AEC3 refines it
  /// internally, but the external hint is what lets its estimator lock when the
  /// two captures have an unknown, hardware-specific offset.
  void processCapture(
    Pointer<Void> handle,
    Pointer<Int16> cap,
    Pointer<Int16> out,
    int frames,
    int streamDelayMs,
  );

  /// Writes the current echo metrics into the supplied scratch pointers.
  ///
  /// Doubles are set to [kAecMetricUnavailable] and `delayMs` to `-1` when AEC3
  /// has no value yet. All four are always written.
  void getMetrics(
    Pointer<Void> handle,
    Pointer<Double> erl,
    Pointer<Double> erle,
    Pointer<Double> residual,
    Pointer<Int32> delayMs,
  );

  /// Destroys an instance returned by [create].
  void destroy(Pointer<Void> handle);

  /// Static engine version string, or `null` when unavailable.
  String? version();
}

/// [AecBindings] over a real `dart:ffi` [DynamicLibrary].
final class FfiAecBindings implements AecBindings {
  FfiAecBindings._(
    this._create,
    this._reverse,
    this._capture,
    this._metrics,
    this._destroy,
    this._version,
  );

  /// Resolves and opens the native library, binding all six symbols.
  ///
  /// Candidates are tried in the order [aecLibraryCandidates] produces, and the
  /// first that opens wins. Throws [AecUnavailable] — listing every path tried
  /// — when none opens, and again when a library opens but is missing a symbol
  /// (a stale or mismatched build, which would otherwise surface later as an
  /// unrelated crash).
  factory FfiAecBindings.open({
    String? libraryPath,
    Map<String, String>? environment,
  }) => FfiAecBindings.openFrom(
    aecLibraryCandidates(libraryPath: libraryPath, environment: environment),
  );

  /// Opens the first of [candidates] that loads, binding all six symbols.
  ///
  /// This is the seam for an embedder whose bundle layout it knows better than
  /// [aecLibraryCandidates] does — a Flutter plugin resolving its own
  /// `Frameworks` directory, say.
  ///
  /// Note that a bare file name can resolve to an image the host process has
  /// *already* loaded, before any file-system lookup. That is deliberate on the
  /// platform's part and usually what a caller wants, but it means a bare name
  /// is not a reliable way to prove nothing is installed; it is the last
  /// candidate for exactly that reason.
  factory FfiAecBindings.openFrom(List<String> candidates) {
    DynamicLibrary? library;
    String? lastError;
    for (final String candidate in candidates) {
      try {
        library = DynamicLibrary.open(candidate);
        break;
      } on Object catch (error) {
        lastError = error.toString();
      }
    }
    if (library == null) {
      throw AecUnavailable(
        'No native echo-cancellation library could be opened.',
        attemptedPaths: candidates,
        cause: lastError,
      );
    }
    return FfiAecBindings.fromLibrary(library);
  }

  /// Binds the six symbols on an already-opened [library].
  ///
  /// Throws [AecUnavailable] when a symbol is missing.
  factory FfiAecBindings.fromLibrary(DynamicLibrary library) {
    try {
      return FfiAecBindings._(
        library
            .lookupFunction<Pointer<Void> Function(Int32, Int32), _CreateDart>(
              'aec_create',
            ),
        library.lookupFunction<
          Void Function(Pointer<Void>, Pointer<Int16>, Int32),
          _ReverseDart
        >('aec_process_reverse', isLeaf: true),
        library.lookupFunction<
          Void Function(
            Pointer<Void>,
            Pointer<Int16>,
            Pointer<Int16>,
            Int32,
            Int32,
          ),
          _CaptureDart
        >('aec_process_capture', isLeaf: true),
        library.lookupFunction<
          Void Function(
            Pointer<Void>,
            Pointer<Double>,
            Pointer<Double>,
            Pointer<Double>,
            Pointer<Int32>,
          ),
          _MetricsDart
        >('aec_get_metrics', isLeaf: true),
        library.lookupFunction<Void Function(Pointer<Void>), _DestroyDart>(
          'aec_destroy',
        ),
        library.lookupFunction<Pointer<Utf8> Function(), _VersionDart>(
          'aec_version',
        ),
      );
    } on Object catch (error) {
      throw AecUnavailable(
        'The native library loaded but does not export the expected AEC '
        'symbols (stale or mismatched build).',
        cause: error.toString(),
      );
    }
  }

  final _CreateDart _create;
  final _ReverseDart _reverse;
  final _CaptureDart _capture;
  final _MetricsDart _metrics;
  final _DestroyDart _destroy;
  final _VersionDart _version;

  @override
  Pointer<Void> create(int sampleRateHz, int numChannels) =>
      _create(sampleRateHz, numChannels);

  @override
  void processReverse(Pointer<Void> handle, Pointer<Int16> ref, int frames) =>
      _reverse(handle, ref, frames);

  @override
  void processCapture(
    Pointer<Void> handle,
    Pointer<Int16> cap,
    Pointer<Int16> out,
    int frames,
    int streamDelayMs,
  ) => _capture(handle, cap, out, frames, streamDelayMs);

  @override
  void getMetrics(
    Pointer<Void> handle,
    Pointer<Double> erl,
    Pointer<Double> erle,
    Pointer<Double> residual,
    Pointer<Int32> delayMs,
  ) => _metrics(handle, erl, erle, residual, delayMs);

  @override
  void destroy(Pointer<Void> handle) => _destroy(handle);

  @override
  String? version() {
    final Pointer<Utf8> pointer = _version();
    return pointer == nullptr ? null : pointer.toDartString();
  }
}

/// Conventional file name of the native library on the current platform.
String platformAecLibraryFileName() {
  if (Platform.isMacOS || Platform.isIOS) {
    return 'libaec_ffi.dylib';
  }
  if (Platform.isWindows) {
    return 'aec_ffi.dll';
  }
  return 'libaec_ffi.so';
}

/// Library paths to try, in order.
///
/// The order is deliberately most-specific first, so a caller can always
/// override whatever an ambient install would have resolved:
///
/// 1. [libraryPath], when supplied — an explicit choice is never second-guessed.
/// 2. The `AUDIO_AEC_LIBRARY` environment variable
///    ([aecLibraryEnvironmentVariable]), for development and CI, where the
///    library is built out of tree.
/// 3. Conventional locations beside the running executable: the executable's own
///    directory, plus the per-platform bundle layout a desktop app uses
///    (`../Frameworks` on macOS, `lib/` on Linux).
/// 4. The bare file name, letting the operating system's own search path
///    resolve it.
///
/// [environment] defaults to the process environment; an embedder that resolves
/// configuration elsewhere — and the tests for this ordering — can supply their
/// own.
List<String> aecLibraryCandidates({
  String? libraryPath,
  Map<String, String>? environment,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final List<String> candidates = <String>[];
  void add(String? path) {
    if (path != null && path.isNotEmpty && !candidates.contains(path)) {
      candidates.add(path);
    }
  }

  add(libraryPath);
  add(env[aecLibraryEnvironmentVariable]);

  final String fileName = platformAecLibraryFileName();
  final String separator = Platform.pathSeparator;
  String? executableDirectory;
  try {
    executableDirectory = File(Platform.resolvedExecutable).parent.path;
  } on Object {
    // Some embedders do not expose a resolved executable. The bare-name
    // candidate below still gives the OS loader a chance.
    executableDirectory = null;
  }
  if (executableDirectory != null) {
    add('$executableDirectory$separator$fileName');
    if (Platform.isMacOS) {
      add(
        '$executableDirectory$separator..${separator}Frameworks'
        '$separator$fileName',
      );
    }
    if (Platform.isLinux) {
      add('$executableDirectory${separator}lib$separator$fileName');
    }
  }
  add(fileName);
  return candidates;
}

typedef _CreateDart = Pointer<Void> Function(int, int);
typedef _ReverseDart = void Function(Pointer<Void>, Pointer<Int16>, int);
typedef _CaptureDart =
    void Function(Pointer<Void>, Pointer<Int16>, Pointer<Int16>, int, int);
typedef _MetricsDart =
    void Function(
      Pointer<Void>,
      Pointer<Double>,
      Pointer<Double>,
      Pointer<Double>,
      Pointer<Int32>,
    );
typedef _DestroyDart = void Function(Pointer<Void>);
typedef _VersionDart = Pointer<Utf8> Function();
