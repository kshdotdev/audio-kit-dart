# Native distribution for `audio_aec` (risk R4)

**Status: resolved — build hooks, with prebuilt binaries fetched and hash-pinned.**
Prototyped and measured on 2026-07-29. Everything below marked "verified" was run
on this machine; everything marked "open" was not, and says why.

| | |
|---|---|
| Dart SDK | 3.12.0 (stable, 2026-05-08) |
| Flutter | 3.44.0 (stable channel, 2026-05-15), Dart 3.12.0 |
| Host | macOS 15 (Darwin 25.5.0), arm64 |

## The question

`audio_aec` binds a ~2.2 MB WebRTC AEC3 shim over six C symbols. Control Center,
which this package is adapted from, is `publish_to: none` and resolves dylibs
that out-of-band scripts drop into an application-support directory. A pub.dev
package cannot do that: it has no install step, no data directory it owns, and
no way to run anything on the consumer's machine — except a build hook.

## Decision matrix

| Option | Consumer cost | Verdict |
|---|---|---|
| **`hook/build.dart` + prebuilt fetch** | none — it is transparent | **chosen.** Stable and unflagged on this toolchain; verified working under `dart test`, `dart run`, `dart build cli`, and `flutter build macos` |
| ffiPlugin building from source | meson + ninja + pkg-config + a C++ toolchain, and a multi-minute clone of webrtc-audio-processing on every clean build | rejected as the default. Kept as an opt-in (`from_source: true`), because it is the only story for a platform we have no binary for |
| Prebuilt binaries checked into the repo | none, but ~2.2 MB per platform in git and in every published tarball forever | rejected. Also loses the ability to reissue a binary without republishing the package |

The third option's fatal flaw is not size, it is that pub.dev tarballs are
immutable. A CVE in WebRTC would mean a new package version; with hashes pinned
in the manifest, it means a new release asset and a patch bump that changes one
constant.

## What was verified, and how

### Build hooks are stable and unflagged here

`--enable-experiment=native-assets` is **rejected** by this SDK
(`Unknown experiment: native-assets`) — the flag belongs to the 2023
experimental era. Build hooks went stable in Dart 3.10 / Flutter 3.38; this
toolchain is well past both. No flag, no `flutter config` toggle
(`--enable-native-assets` still exists in `flutter config` but is not needed).

### Which commands honour hooks

Verified by running each one against the example consumer in `example/`:

| Command | Hooks run? | Notes |
|---|---|---|
| `dart test` | **yes** | This is the one the task hinged on. Verified. |
| `dart run` | **yes** | |
| `dart build cli` | **yes** | Bundles `lib/libaec_ffi.dylib` next to the exe; the bundle runs from anywhere |
| `flutter build macos` | **yes** | Wraps the dylib in `aec_ffi.framework` (see below) |
| **`dart compile exe`** | **no — hard error** | `'dart compile' does not support build hooks, use 'dart build' instead. Packages with build hooks: audio_aec.` |

`dart compile exe` is the one real cost of this decision, and it is **transitive
and unavoidable**: any consumer who depends on `audio_aec`, however indirectly,
must switch that step to `dart build cli`. This belongs in the package README,
not buried here. It is not a bug — `dart build` is the replacement — but it will
break someone's release pipeline the day they add this dependency.

### Assets are addressed by asset id, not by path

A registered code asset has **no stable filesystem path**: the SDK copies it
next to the build output and rewrites its install name. Verified:

```dart
DynamicLibrary.open('package:audio_aec/src/native_asset_bindings.dart')
// -> Invalid argument(s): Failed to load dynamic library ... (no such file)
```

It is treated as a literal filename. The only mechanism that resolves an asset
id is a `@Native` external function, so consuming a hook-supplied library needs
a *second* `AecBindings` implementation, not a new candidate path in the
existing loader. That is `lib/src/native_asset_bindings.dart`, and it is why
`FfiAecBindings` is untouched by this work.

Resolution is lazy and per-symbol. With no asset bundled, the first call throws:

```
Invalid argument(s): Couldn't resolve native function 'aec_version' in
'package:audio_aec/src/native_asset_bindings.dart' : No asset with id ... found.
```

`NativeAssetAecBindings.tryResolve()` turns that into a `null`, which is what
lets `AecProcessor.create()` fall through to the path-based loader.

### Environment variables do not reach a hook

Hooks run in a **semi-hermetic environment**: `Platform.environment` is stripped
to an allow-list (`PATH`, `HOME`, `TEMP`/`TMPDIR`, `HTTP_PROXY`/`HTTPS_PROXY`/
`NO_PROXY`, `ANDROID_*`, `CCACHE_*`, `NIX_*`, `LIBCLANG_PATH`). Verified by
printing it from inside the hook:

```
AUDIO_AEC_FROM_SOURCE=1 dart test   ->   hook sees: null
```

This is deliberate — hook inputs must be declared to be cacheable — and it
**invalidates the obvious design** of gating the from-source path on an
environment variable. Every knob is therefore a `hooks.user_defines.audio_aec`
key in the consumer's **workspace-root** `pubspec.yaml` (member-package defines
are silently ignored). The proxy variables being on the allow-list is the
SDK telling you network access in a hook is anticipated and supported.

### The `-headerpad_max_install_names` trap

**This was a genuine bug in `tool/build_native.sh`, found by the prototype and
fixed in it.** The first hook run failed:

```
install_name_tool: changing install names or rpaths can't be redone for:
  .../.dart_tool/lib/libaec_ffi.dylib (for architecture arm64) because larger
  updated load commands do not fit (the program must be relinked, and you may
  need to use -headerpad or -headerpad_max_install_names)
```

The SDK rewrites `LC_ID_DYLIB` to the absolute path it copied the library to.
Our dylib was linked with `-install_name @rpath/libaec_ffi.dylib` (23 chars) and
had **56 bytes** of Mach-O header padding — nowhere near enough for a real
absolute path.

Proven causal with an A/B test on a six-symbol stub, identical in every respect
except the link flag:

| | header pad | `dart test` |
|---|---|---|
| without `-headerpad_max_install_names` | 32 bytes | fails, as above |
| with it | 2048 bytes | passes |

The real library after the fix has 5144 bytes of pad and works. Any project
handing a macOS dylib to a build hook needs this flag; it is not optional and
the failure is at the consumer's build, not yours.

### Dependency constraint: `hooks: ^2.0.0`, not `^2.1.0`

`hooks` 2.1.0 requires `meta ^1.19.0`. Flutter 3.44.0's bundled `flutter_test`
pins `meta` to **1.18.0**, so 2.1.0 cannot resolve in any workspace containing a
Flutter package — version solving fails outright. `^2.0.0` lets the solver
settle on 2.0.2 (`meta ^1.16.0`) there and still take 2.1.0 in a pure-Dart
consumer. Revisit when Flutter's pin moves.

### Publishing is permitted

`dart pub publish --dry-run` reports **no hook-related warning**, and
`hook/build.dart` + `hook/prebuilt_manifest.dart` are included in the archive.
(The two warnings it does report are a dirty git tree and the changelog.)
Precedent: `cupertino_http` and `sqlite3` both ship `hook/build.dart` today.

## macOS signing and notarization

The question was: does a *downloaded*, ad-hoc-signed dylib load?

**In a development Flutter app: yes, verified.** `flutter build macos --debug`
followed by launching the `.app` printed
`AEC_ASSET_VERSION=webrtc-audio-processing-2.1+aec3`.

Three findings behind that:

1. **No quarantine.** A file written by the hook via `HttpClient` +
   `File.writeAsBytes` carries only `com.apple.provenance`, **not**
   `com.apple.quarantine` — Gatekeeper's quarantine flag is applied by
   LaunchServices-aware downloaders (browsers), not by raw socket writes. So
   nothing to staple, nothing to `xattr -d`.
2. **Flutter re-signs it anyway.** The dylib does not ship as a dylib: Flutter
   wraps it in `aec_ffi.framework` and signs it ad-hoc with its own identifier,
   `io.flutter.flutter.native-assets.aec-ffi`. Whatever signature
   `build_native.sh` applied is irrelevant by the time the app is built — it is
   overwritten. `dart build cli` differs: it keeps a bare
   `lib/libaec_ffi.dylib` with install name `@rpath/lib/libaec_ffi.dylib` and
   leaves the ad-hoc signature in place.
3. **Ad-hoc is sufficient for loading**, on arm64, where *some* valid signature
   is mandatory but it need not be a Developer ID.

**For release and notarization — open, not verified.** The reasoning, to be
confirmed before anyone ships:

- Xcode re-signs everything in `Contents/Frameworks` with the app's Developer ID
  during an archive build, so the framework inherits the app's identity. This is
  the same path any third-party framework takes and there is no reason
  native-asset frameworks differ — but it was not tested, because doing so needs
  a paid Developer ID this machine does not have.
- The **hardened runtime** is the real risk. It is required for notarization,
  and it enforces that loaded libraries are signed by the same Team ID as the
  app, or bear a valid Developer ID. An ad-hoc signature satisfies neither.
  Since Xcode re-signs, this should be fine; if it is not, the fallback is
  `com.apple.security.cs.disable-library-validation`, which is a real
  entitlement with real security cost and should be a last resort.
- **We must not ship a Developer-ID-signed dylib ourselves.** A downloaded
  binary signed by *our* team ID inside *someone else's* app is worse than an
  unsigned one: it will fail library validation against their Team ID. Ad-hoc,
  and let the consumer's toolchain sign it, is correct.

**Action before first release:** build a release-configuration Flutter app with
a real Developer ID, notarize it, and confirm the framework passes
`spctl -a -vvv`. Until that is done, this package should be considered
verified-for-development only on macOS.

## Windows and Linux — open

Neither was exercised; this machine is macOS arm64.

- **Linux.** `tool/build_native.sh`'s Linux path is inherited from Control
  Center and has never been run here. The header-padding problem is
  macOS-specific (ELF uses `DT_SONAME` and `RPATH`, and the loader does not
  rewrite them), so the equivalent trap is probably absent, but "probably" is
  the accurate word. Needs a CI runner.
- **Windows.** Not covered at all — `build_native.sh` is bash and the upstream
  project builds with MSVC separately. `from_source` refuses on Windows with a
  clear message rather than pretending. A Windows binary has to come from the
  prebuilt path, which means CI has to produce one.
- **Apple constraint to respect when adding architectures:** the library
  filename must be identical across every target OS/arch, because Flutter's
  framework and XCFramework generation depends on it. `installedLibraryName()`
  in `hook/prebuilt_manifest.dart` is what enforces that; the per-target
  distinction lives in the *artifact* name, which is only a URL component.

## The design

`hook/build.dart` tries four strategies in order and **never fails a build**:

1. `prebuilt` — a library file already on disk. The vendor-your-own escape
   hatch, and what `example/` uses.
2. `prebuilt_url` / `prebuilt_url_base` — download, verify sha256, register.
3. `from_source: true` — run `tool/build_native.sh`, if meson is present.
4. Nothing, plus an actionable diagnostic on stderr.

### Configuration

All keys live under `hooks.user_defines.audio_aec` in the **workspace-root**
`pubspec.yaml`:

| Key | Meaning |
|---|---|
| `prebuilt` | Path to a library file, resolved relative to the pubspec |
| `prebuilt_url` | Explicit URL for this platform's artifact (`https:` or `file:`) |
| `prebuilt_url_base` | Base URL; the artifact name is appended |
| `prebuilt_sha256` | Expected hash. **Quote it** — YAML types a bare all-digit hash as an integer |
| `allow_unpinned` | `true` to fetch without a hash. Off by default |
| `from_source` | `true` to build with meson |

### Hash pinning is mandatory by default

A download is **refused** when no sha256 is known for the target, from either
`prebuilt_sha256` or the built-in `pinnedSha256` manifest. An unpinned fetch is
a supply-chain hole: whoever controls the URL controls code running in every
consumer's build, at build time, with the developer's privileges. Verified both
ways — a correct hash registers the asset; a wrong one prints the expected and
actual digests, registers nothing, and the consumer suite *skips* rather than
errors:

```
audio_aec: sha256 mismatch for file:///...
  expected deadbeef...
  actual   91b73004029b4936ee3dc74ca048faa525950416d2d4b9ae50da2f98bf3cf173
```

`pinnedSha256` in `hook/prebuilt_manifest.dart` is **empty until the first
release**, so today the hook produces nothing unless a consumer configures it.
That is the honest state and it is why the default URL base is not reachable yet.

### Additivity

The hook cannot regress anyone:

- It never calls `setFailure`. Producing nothing is a normal outcome.
- `AecProcessor.create()` prefers an explicit `libraryPath`, then the code
  asset, then the unchanged `aecLibraryCandidates` policy
  (`AUDIO_AEC_LIBRARY` → conventional locations → bare name).
- A consumer whose SDK never runs hooks is in exactly the pre-hook state.
- The parent package's 67 tests pass unchanged, with the hook present and
  producing nothing.

The code asset sits *below* an explicit path and *above* the environment
variable deliberately: the hook is the only candidate the consumer did not have
to arrange by hand, so preferring it makes the packaged path the default, while
`libraryPath` remains the way to force a specific library.

## Reproducing the proof

```bash
packages/audio_aec/tool/build_native.sh          # once; needs meson + ninja
cd packages/audio_aec/example && dart pub get
env -u AUDIO_AEC_LIBRARY dart test               # 2 tests, via the hook only
```

The example suite asserts `AUDIO_AEC_LIBRARY` is unset before it runs, so it
cannot accidentally prove the old path instead of the new one.

```bash
packages/audio_aec/tool/verify_hook.sh           # download + hash, both outcomes
```

## Migration steps

1. **CI produces binaries.** Add jobs for macos-arm64, macos-x64, linux-x64 and
   windows-x64. macOS must link with `-headerpad_max_install_names` (already in
   `build_native.sh`); Windows needs an MSVC recipe that does not exist yet.
2. **Release them** under a tag matching `artifactVersion` in
   `hook/prebuilt_manifest.dart`, named `aec_ffi-<os>-<arch>.<ext>`.
3. **Pin the hashes** into `pinnedSha256`. This is the only edit needed to turn
   the default path on, and it is what makes `defaultUrlBase` reachable.
4. **Ship the BSD-3 notice with the binary.** `NOTICE` obliges attribution in
   binary distributions; the release assets need a third-party notices file
   beside them, since the dylib now travels independently of the pub package.
5. **Verify notarization** on a release Flutter app with a real Developer ID
   before declaring macOS production-ready.
6. **Document `dart compile exe`** in the README — consumers must use
   `dart build cli`.
