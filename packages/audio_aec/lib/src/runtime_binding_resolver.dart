import 'bindings.dart';
import 'native_asset_bindings.dart';

/// Resolves the bindings used by both a real processor and the capability
/// probe. Keeping the policy in one place prevents a probe from claiming a
/// different runtime than [AecProcessor] will actually open.
AecBindings resolveAecRuntimeBindings({String? libraryPath}) =>
    (libraryPath == null ? NativeAssetAecBindings.tryResolve() : null) ??
    FfiAecBindings.open(libraryPath: libraryPath);
