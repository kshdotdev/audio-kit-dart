// The prebuilt-artifact naming scheme and its sha256 pins.
//
// Kept separate from `build.dart` so the release process has exactly one file
// to touch: cut a release, upload the per-platform artifacts, drop their
// hashes into [pinnedSha256]. Nothing else in the package changes.

/// Artifact file name for a target, e.g. `aec_ffi-macos-arm64.dylib`.
///
/// The triple is in the name rather than in the path so that a GitHub release —
/// a flat bag of files under one tag — can host every platform at once. [os]
/// and [arch] are the lowercase `OS`/`Architecture` names `package:code_assets`
/// already uses (`macos`, `linux`, `windows`; `arm64`, `x64`), so the hook does
/// not carry a translation table that could drift from theirs.
String prebuiltArtifactName({required String os, required String arch}) =>
    'aec_ffi-$os-$arch.${_extension(os)}';

/// File name the *loader* expects on disk, which is not the artifact name.
///
/// The downloaded artifact is renamed to this before it is registered, so a
/// library resolved through a build hook and one resolved through
/// `AUDIO_AEC_LIBRARY` have the same name on disk. That matters when someone is
/// reading `otool -L` output or a crash log and trying to tell the two apart.
String installedLibraryName(String os) =>
    os == 'windows' ? 'aec_ffi.dll' : 'libaec_ffi.${_extension(os)}';

String _extension(String os) => switch (os) {
  'macos' || 'ios' => 'dylib',
  'windows' => 'dll',
  _ => 'so',
};

/// Default base URL for released artifacts.
///
/// Overridable with the `prebuilt_url_base` user-define. The version is the
/// native ABI release in [artifactVersion], rather than `latest`, because a
/// build hook that silently picks up a new binary is not reproducible.
const String defaultUrlBase =
    'https://github.com/kshdotdev/audio-kit-dart/releases/download/'
    'audio_aec-native-v$artifactVersion';

/// Release tag component of [defaultUrlBase].
///
/// This tracks the *ABI*, not the package version: it changes when
/// `native/aec_ffi.cc` or the pinned webrtc-audio-processing revision changes,
/// not when Dart-side code does. Bumping the package version does not invalidate
/// a binary whose ABI is unchanged.
const String artifactVersion = '0.1.0';

/// sha256 of each released artifact, keyed by `<os>-<arch>`.
///
/// **Empty by design until the first release.** A download is refused when the
/// target is not in this map, because an unpinned fetch over the network is a
/// supply-chain hole: whoever controls the URL controls code running in every
/// consumer's build. The escape hatches are the `prebuilt_sha256` user-define
/// (pin it yourself) and `allow_unpinned` (explicitly accept the risk); neither
/// is the default.
///
/// Generate a reviewed replacement after the native workflow succeeds with:
/// ```sh
/// python3 tool/prebuilt_release.py render-pins \
///   --manifest release/audio_aec-prebuilt-manifest.json \
///   --directory release
/// ```
const Map<String, String> pinnedSha256 = <String, String>{
  // 'macos-arm64': '<sha256>',
  // 'macos-x64': '<sha256>',
  // 'linux-x64': '<sha256>',
  // 'windows-x64': '<sha256>',
};
