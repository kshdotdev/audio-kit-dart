// Adapted from Control Center's `packages/cc_natives/lib/src/audio/aec/
// aec_processor.dart`.
// Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.
//
// Adaptation notes:
//   - Blocks are [Int16List], not [Uint8List]. Control Center's captures are
//     PCM16 byte streams, so its processor marshals bytes and has to name an
//     endianness at every hop. Audio Kit is float32-native and converts at the
//     block boundary in `AecBlockAccumulator`, so the processor's unit is a
//     sample list and the byte-order question never arises.
//   - The block-size contract throws instead of asserting. The original uses
//     `assert`, which is compiled out in release; a wrong-sized block would then
//     silently read stale scratch or truncate, which is a memory-correctness
//     bug rather than a wrong number.
//   - [AecEngine] carries [sampleRate] / [blockFrames] so a composing filter can
//     verify the audio format it is about to feed actually matches the engine
//     that was created. Feeding 48 kHz blocks to a 16 kHz AEC3 instance produces
//     no error and no cancellation, which is the worst available outcome.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// AEC3 echo metrics. Every field is `null` until AEC3 has a value.
final class AecMetrics {
  /// Creates a metrics snapshot; an omitted field means "no value yet".
  const AecMetrics({this.erl, this.erle, this.residual, this.delayMs});

  /// An all-null snapshot: no data yet, or no engine.
  static const AecMetrics empty = AecMetrics();

  /// Echo return loss, in dB.
  final double? erl;

  /// Echo return loss enhancement, in dB.
  ///
  /// This is the "is it actually working" signal: greater than 0 means AEC3 is
  /// actively removing echo, and `null` or approximately 0 means it is not.
  final double? erle;

  /// Residual-echo likelihood, in `[0, 1]`.
  final double? residual;

  /// AEC3's own internal echo-path delay estimate, in milliseconds.
  ///
  /// Independent of the external hint fed to
  /// [AecEngine.processCapture]; comparing the two is the quickest way to tell
  /// whether a measured delay is being believed.
  final int? delayMs;

  @override
  String toString() {
    String show(double? value) =>
        value == null ? 'n/a' : value.toStringAsFixed(1);
    return 'AecMetrics(erl: ${show(erl)}dB, erle: ${show(erle)}dB, '
        'residual: ${show(residual)}, delay: ${delayMs ?? 'n/a'}ms)';
  }
}

/// The echo-cancellation capability a composing filter depends on.
///
/// Implemented by [AecProcessor] over FFI; tests supply a fake. Keeping the
/// filter bound to this interface rather than to [AecProcessor] is what lets a
/// caller with no far-end reference — in-person capture, or a platform where no
/// native library exists — drop to identity passthrough without any call site
/// learning about it.
abstract interface class AecEngine {
  /// Sample rate the engine was created for, in hertz.
  int get sampleRate;

  /// Samples in one processing block: 10 ms, i.e. [sampleRate] / 100.
  int get blockFrames;

  /// Feeds one far-end (loopback) reference block of exactly [blockFrames]
  /// samples.
  void processReverse(Int16List block);

  /// Cleans one near-end (mic) block of exactly [blockFrames] samples and
  /// returns the echo-removed block.
  ///
  /// [streamDelayMs] is the measured far-end→capture lead handed to AEC3.
  Int16List processCapture(Int16List block, int streamDelayMs);

  /// The engine's current echo metrics.
  AecMetrics metrics();

  /// Releases native resources. Idempotent.
  void dispose();
}

/// Stateful owner of one native WebRTC AEC3 instance.
///
/// Cancels speaker bleed out of the microphone using a system loopback as the
/// far-end reference. Works on fixed 10 ms blocks of mono PCM16 ([blockFrames]
/// samples). Feed each far-end block via [processReverse] and each near-end
/// block via [processCapture]; AEC3 aligns the two internally, guided by the
/// external delay hint.
///
/// ## Main-isolate only
///
/// This class owns a raw native [Pointer]. A pointer is an address in this
/// process's heap with no ownership or synchronization attached: it is not
/// sendable across isolates, and the AEC3 instance behind it is stateful — it
/// carries the adaptive filter, the render buffer, and the delay estimate that
/// each block updates. Two isolates calling it would interleave those updates
/// against an object with no internal locking. Every call for a given processor
/// must therefore come from the isolate that created it.
///
/// This is not a limitation worth engineering around. Each 10 ms block is
/// sub-millisecond work, so the cost of processing inline is far below the cost
/// of copying audio across a port; and Audio Kit's stream graph is main-isolate
/// plumbing already.
///
/// ## Failure model
///
/// [AecProcessor.create] throws [AecUnavailable] when the native library is
/// absent or incompatible. That is a broken install rather than a runtime
/// condition, so it fails loudly instead of quietly recording an echo-laden
/// track.
final class AecProcessor implements AecEngine {
  AecProcessor._(this._bindings, this._handle, this.sampleRate, this.channels)
    : blockFrames = sampleRate ~/ 100,
      _ref = malloc<Int16>(sampleRate ~/ 100),
      _cap = malloc<Int16>(sampleRate ~/ 100),
      _out = malloc<Int16>(sampleRate ~/ 100),
      _metricErl = malloc<Double>(),
      _metricErle = malloc<Double>(),
      _metricResidual = malloc<Double>(),
      _metricDelay = malloc<Int32>();

  /// Loads the native library and creates an instance.
  ///
  /// [libraryPath] short-circuits the resolution order documented on
  /// [aecLibraryCandidates]. Throws [AecUnavailable] when the library cannot be
  /// resolved or loaded, or when the engine refuses the requested format. There
  /// is no degraded mode; see the class documentation.
  factory AecProcessor.create({
    String? libraryPath,
    int sampleRate = 16000,
    int channels = 1,
  }) => AecProcessor.fromBindings(
    FfiAecBindings.open(libraryPath: libraryPath),
    sampleRate: sampleRate,
    channels: channels,
  );

  /// Creates an instance over already-resolved [bindings].
  ///
  /// This is the seam tests use: supply a fake [AecBindings] and the whole
  /// marshalling path below is exercised without a native library.
  factory AecProcessor.fromBindings(
    AecBindings bindings, {
    int sampleRate = 16000,
    int channels = 1,
  }) {
    if (sampleRate <= 0 || sampleRate % 100 != 0) {
      throw ArgumentError.value(
        sampleRate,
        'sampleRate',
        'Must be positive and a multiple of 100 so a 10 ms block is a whole '
            'number of samples.',
      );
    }
    if (channels != 1) {
      throw ArgumentError.value(
        channels,
        'channels',
        'Only mono is supported: the far-end reference and the capture must '
            'share one channel layout, and every Audio Kit AEC path is mono.',
      );
    }
    final Pointer<Void> handle = bindings.create(sampleRate, channels);
    if (handle == nullptr) {
      throw AecUnavailable(
        'aec_create returned null (sampleRate: $sampleRate, '
        'channels: $channels).',
      );
    }
    return AecProcessor._(bindings, handle, sampleRate, channels);
  }

  /// Sample rate the native instance was created for.
  @override
  final int sampleRate;

  /// Channel count the native instance was created for. Always 1.
  final int channels;

  /// Samples per processing block: 10 ms at [sampleRate].
  @override
  final int blockFrames;

  final AecBindings _bindings;
  final Pointer<Void> _handle;
  final Pointer<Int16> _ref;
  final Pointer<Int16> _cap;
  final Pointer<Int16> _out;
  final Pointer<Double> _metricErl;
  final Pointer<Double> _metricErle;
  final Pointer<Double> _metricResidual;
  final Pointer<Int32> _metricDelay;
  bool _disposed = false;

  /// Whether [dispose] has run.
  bool get isDisposed => _disposed;

  /// Native engine version string, for logging and FFI smoke tests.
  String? get version => _bindings.version();

  @override
  void processReverse(Int16List block) {
    _requireBlock(block, 'reverse');
    if (_disposed) {
      return;
    }
    _ref.asTypedList(blockFrames).setAll(0, block);
    _bindings.processReverse(_handle, _ref, blockFrames);
  }

  @override
  Int16List processCapture(Int16List block, int streamDelayMs) {
    _requireBlock(block, 'capture');
    if (_disposed) {
      return block;
    }
    _cap.asTypedList(blockFrames).setAll(0, block);
    _bindings.processCapture(_handle, _cap, _out, blockFrames, streamDelayMs);
    // Copy out of the reusable scratch buffer: the returned block outlives this
    // call and the next call would overwrite it in place.
    return Int16List.fromList(_out.asTypedList(blockFrames));
  }

  @override
  AecMetrics metrics() {
    if (_disposed) {
      return AecMetrics.empty;
    }
    _bindings.getMetrics(
      _handle,
      _metricErl,
      _metricErle,
      _metricResidual,
      _metricDelay,
    );
    double? value(Pointer<Double> pointer) {
      final double raw = pointer.value;
      return raw <= kAecMetricUnavailable ? null : raw;
    }

    final int delay = _metricDelay.value;
    return AecMetrics(
      erl: value(_metricErl),
      erle: value(_metricErle),
      residual: value(_metricResidual),
      delayMs: delay < 0 ? null : delay,
    );
  }

  /// Destroys the native instance and frees the scratch buffers. Idempotent.
  ///
  /// Callers must stop feeding blocks before calling this: a block in flight
  /// when the handle is destroyed is a use-after-free. [AecMicFilter] enforces
  /// the ordering by cancelling both capture subscriptions first.
  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _bindings.destroy(_handle);
    malloc
      ..free(_ref)
      ..free(_cap)
      ..free(_out)
      ..free(_metricErl)
      ..free(_metricErle)
      ..free(_metricResidual)
      ..free(_metricDelay);
  }

  void _requireBlock(Int16List block, String role) {
    if (block.length != blockFrames) {
      throw ArgumentError.value(
        block.length,
        '$role block length',
        'Must be exactly $blockFrames samples (10 ms at $sampleRate Hz). '
            'Chop captures with AecBlockAccumulator rather than submitting '
            'whatever size the backend delivered.',
      );
    }
  }
}
