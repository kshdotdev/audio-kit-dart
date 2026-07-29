// Build hook: supplies the native AEC3 library as a code asset, when it can.
//
// This hook is ADDITIVE. It never fails a build. When it can produce nothing it
// says so on stderr and exits cleanly with no assets, and the runtime loader in
// `lib/src/bindings.dart` — explicit path, then `AUDIO_AEC_LIBRARY`, then
// conventional locations — behaves exactly as it did before the hook existed.
// A consumer on an SDK that does not run hooks at all is in that same state.
//
// Strategy, in order:
//   1. `prebuilt` user-define      — a library file already on disk.
//   2. `prebuilt_url` / `_url_base`— download, verify sha256, register.
//   3. `from_source` user-define   — run tool/build_native.sh (needs meson).
//   4. Nothing, with a diagnostic.
//
// ## Configuration is user-defines, not environment variables
//
// Hooks run in a SEMI-HERMETIC environment: `Platform.environment` is stripped
// to an allow-list (PATH, HOME, TEMP, HTTP_PROXY, ANDROID_*, CCACHE_*, NIX_*).
// A variable like `AUDIO_AEC_FROM_SOURCE=1` set in the consumer's shell is
// simply NOT VISIBLE here — verified on Dart 3.12.0, see doc/DISTRIBUTION.md.
// That is deliberate on the SDK's part: hook inputs have to be declared to be
// cacheable. So every knob below is a `hooks.user_defines.audio_aec` key in the
// consumer's workspace-root `pubspec.yaml`, which the SDK hashes into the cache
// key.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

import 'prebuilt_manifest.dart';

void main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    // `buildCodeAssets` is false for e.g. a pure `dart analyze`, or a Flutter
    // build whose native-assets support is switched off. Doing the work anyway
    // would download a few megabytes nobody asked for.
    if (!input.config.buildCodeAssets) {
      return;
    }

    final CodeConfig code = input.config.code;
    final String os = code.targetOS.name;
    final String arch = code.targetArchitecture.name;
    final String target = '$os-$arch';

    final File? library = await _resolveLibrary(input, output, os, arch);
    if (library == null) {
      _diagnose(target);
      return;
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        // Must match the @DefaultAsset on lib/src/native_asset_bindings.dart.
        name: 'src/native_asset_bindings.dart',
        // Bundled: the SDK copies this file next to the consumer's output and
        // owns its install name from here on. It is NOT DynamicLoadingSystem —
        // there is no system-wide libaec_ffi to find.
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );
    stderr.writeln(
      'audio_aec: registered ${library.path} as a code asset for $target.',
    );
  });
}

/// Runs the strategies in precedence order; `null` means none produced a file.
Future<File?> _resolveLibrary(
  BuildInput input,
  BuildOutputBuilder output,
  String os,
  String arch,
) async {
  // 1. An explicit local file. This is the vendor-your-own-binary escape hatch,
  //    and it is what the prototype harness in tool/ uses. Trusted verbatim:
  //    the consumer named a path on their own disk, so a hash check would only
  //    protect them from themselves.
  final Uri? local = input.userDefines.path('prebuilt');
  if (local != null) {
    final File file = File.fromUri(local);
    // Declared even when missing, so creating it later re-runs the hook.
    output.dependencies.add(local);
    if (file.existsSync()) {
      return file;
    }
    stderr.writeln(
      'audio_aec: hooks.user_defines.audio_aec.prebuilt points at '
      '${file.path}, which does not exist.',
    );
    return null;
  }

  // 2. A pinned download.
  final _Download? download = _plan(input, os, arch);
  if (download != null) {
    return _fetch(input, download, os);
  }

  // 3. Build from source, only when explicitly asked.
  if (input.userDefines['from_source'] == true) {
    return _buildFromSource(input, os);
  }
  return null;
}

/// What to fetch and what it must hash to; `null` when no URL is configured.
_Download? _plan(BuildInput input, String os, String arch) {
  final Object? explicitUrl = input.userDefines['prebuilt_url'];
  final Object? base = input.userDefines['prebuilt_url_base'];
  final Object? pin = input.userDefines['prebuilt_sha256'];
  final bool allowUnpinned = input.userDefines['allow_unpinned'] == true;

  // No released artifacts exist yet, so the default base is not used unless the
  // consumer opts in by pinning a hash. Reaching for `defaultUrlBase` with an
  // empty manifest would produce a 404 on every build.
  //
  // `pin` is stringified rather than type-tested because YAML types an unquoted
  // all-digit hash as an *integer*, and silently treating that as "no pin
  // supplied" would downgrade a consumer's verification to none — the one
  // failure mode this code exists to prevent.
  final String? expected = pin?.toString().trim() ?? pinnedSha256['$os-$arch'];
  final String? resolvedBase = base is String
      ? base
      : (expected != null ? defaultUrlBase : null);

  final Uri? url = switch (explicitUrl) {
    final String value => Uri.parse(value),
    _ =>
      resolvedBase == null
          ? null
          : Uri.parse(
              '${resolvedBase.endsWith('/') ? resolvedBase : '$resolvedBase/'}'
              '${prebuiltArtifactName(os: os, arch: arch)}',
            ),
  };
  if (url == null) {
    return null;
  }

  if (expected == null && !allowUnpinned) {
    stderr.writeln(
      'audio_aec: refusing to fetch $url — no sha256 pin for $os-$arch. '
      'Whoever controls that URL would control code running in this build. '
      'Set hooks.user_defines.audio_aec.prebuilt_sha256, or allow_unpinned: '
      'true to accept the risk.',
    );
    return null;
  }
  return _Download(url, expected);
}

/// Downloads (or copies, for `file:`) and verifies. `null` on any failure.
///
/// Failures here are reported and swallowed rather than raised: a package whose
/// build breaks because a release server had a bad minute is worse than one
/// that falls back to `AUDIO_AEC_LIBRARY`.
Future<File?> _fetch(BuildInput input, _Download plan, String os) async {
  // outputDirectoryShared survives across builds and is shared between targets,
  // so a second `dart test` in the same workspace does not re-download.
  final Uri cacheUri = input.outputDirectoryShared.resolve(
    installedLibraryName(os),
  );
  final File cached = File.fromUri(cacheUri);
  if (cached.existsSync() &&
      (plan.sha256 == null || _hash(cached) == plan.sha256)) {
    return cached;
  }

  List<int> bytes;
  try {
    if (plan.url.scheme == 'file') {
      bytes = await File.fromUri(plan.url).readAsBytes();
    } else {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request = await client.getUrl(plan.url);
        final HttpClientResponse response = await request.close();
        if (response.statusCode != 200) {
          stderr.writeln(
            'audio_aec: ${plan.url} returned HTTP ${response.statusCode}.',
          );
          return null;
        }
        bytes = await response.fold<List<int>>(
          <int>[],
          (List<int> acc, List<int> chunk) => acc..addAll(chunk),
        );
      } finally {
        client.close();
      }
    }
  } on Object catch (error) {
    stderr.writeln('audio_aec: fetching ${plan.url} failed: $error');
    return null;
  }

  final String actual = sha256.convert(bytes).toString();
  if (plan.sha256 != null && actual != plan.sha256) {
    stderr.writeln(
      'audio_aec: sha256 mismatch for ${plan.url}\n'
      '  expected ${plan.sha256}\n'
      '  actual   $actual\n'
      'Refusing to register it. Nothing was installed.',
    );
    return null;
  }

  await cached.parent.create(recursive: true);
  await cached.writeAsBytes(bytes, flush: true);
  // The download arrives without the executable bit on some filesystems, and a
  // dylib that cannot be read back is a confusing failure later.
  if (!Platform.isWindows) {
    await Process.run('chmod', <String>['755', cached.path]);
  }
  stderr.writeln('audio_aec: fetched ${plan.url} (sha256 $actual).');
  return cached;
}

/// Runs `tool/build_native.sh`, which needs meson, ninja and a C++ toolchain.
Future<File?> _buildFromSource(BuildInput input, String os) async {
  if (os == 'windows') {
    stderr.writeln(
      'audio_aec: from_source is not supported on Windows — '
      'tool/build_native.sh is a bash script and the MSVC path is not covered.',
    );
    return null;
  }
  final File script = File.fromUri(
    input.packageRoot.resolve('tool/build_native.sh'),
  );
  if (!script.existsSync()) {
    stderr.writeln('audio_aec: ${script.path} is missing.');
    return null;
  }
  // A published package's `tool/` is present but meson usually is not, so check
  // before spending a clone on it.
  final ProcessResult probe = await Process.run('meson', <String>['--version']);
  if (probe.exitCode != 0) {
    stderr.writeln(
      'audio_aec: from_source requested but meson is not on PATH. '
      'Install meson, ninja and pkg-config, or drop from_source.',
    );
    return null;
  }

  final Uri dest = input.outputDirectoryShared.resolve('from_source/');
  stderr.writeln(
    'audio_aec: building from source (meson ${(probe.stdout as String).trim()})'
    ' — this clones webrtc-audio-processing and takes several minutes.',
  );
  final ProcessResult result = await Process.run(script.path, <String>[
    dest.toFilePath(),
  ], runInShell: true);
  if (result.exitCode != 0) {
    stderr.writeln(
      'audio_aec: tool/build_native.sh failed (exit ${result.exitCode}):\n'
      '${result.stderr}',
    );
    return null;
  }
  final File built = File.fromUri(dest.resolve(installedLibraryName(os)));
  return built.existsSync() ? built : null;
}

String _hash(File file) => sha256.convert(file.readAsBytesSync()).toString();

/// The nothing-to-do message. Deliberately actionable and deliberately not an
/// error: this is the package's documented default state.
void _diagnose(String target) {
  stderr.writeln(
    'audio_aec: no native library for $target — registering no code asset.\n'
    '  This is not a build failure. AecProcessor.create() still resolves an\n'
    '  explicit libraryPath or \$AUDIO_AEC_LIBRARY at runtime, and throws\n'
    '  AecUnavailable listing every path tried if neither is set.\n'
    '  To have this hook supply one, add to your workspace pubspec.yaml:\n'
    '    hooks:\n'
    '      user_defines:\n'
    '        audio_aec:\n'
    '          prebuilt: path/to/${installedLibraryName(target.split('-').first)}\n'
    '  See package:audio_aec doc/DISTRIBUTION.md for the other strategies.',
  );
}

/// A planned fetch: where from, and what it must hash to (`null` = unpinned).
final class _Download {
  const _Download(this.url, this.sha256);

  final Uri url;
  final String? sha256;
}
