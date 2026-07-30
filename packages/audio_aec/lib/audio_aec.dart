/// Acoustic echo cancellation for Audio Kit streams over WebRTC AEC3.
///
/// The package is three layers: a six-symbol `dart:ffi` binding and its loader
/// ([AecBindings], [FfiAecBindings], [AecUnavailable]), a stateful wrapper over
/// one native engine instance ([AecProcessor]), and the [AudioSource]-shaped
/// composition that wires a microphone and a loopback reference through it
/// ([AecMicFilter]).
///
/// The pure, schedulable math this builds on — envelope cross-correlation delay
/// estimation and 10 ms block accumulation — lives in `audio_processing` and is
/// usable without any native library.
///
/// **This package does not ship a native binary**; see the README for the
/// loader's resolution order and the state of native distribution.
library;

export 'src/bindings.dart';
export 'src/mic_filter.dart';
export 'src/native_asset_bindings.dart';
export 'src/processor.dart';
