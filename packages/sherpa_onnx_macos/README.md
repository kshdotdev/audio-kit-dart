# sherpa_onnx_macos compatibility package

This private workspace package replaces the `sherpa_onnx_macos` 1.13.4
platform package during Audio Kit and Concepta Copilot development. It keeps
the upstream Dart API unchanged while providing universal ONNX Runtime and
Sherpa dylibs whose arm64 and x86_64 slices both target macOS 12.0.

The public 1.13.4 package cannot be used by a macOS 12 application: its
`libonnxruntime.1.27.0.dylib` currently declares macOS 15.5 in both slices even
though its podspec declares 10.11. The build linker warning is therefore a real
runtime incompatibility, not a warning to suppress.

The checked-in binaries are built from the exact upstream 1.27.0 and 1.13.4
sources. See [BUILD_PROVENANCE.md](BUILD_PROVENANCE.md) and rebuild them with:

```sh
./tool/sherpa_macos/build.sh
```

The rebuilt ONNX Runtime is packaged as `libonnxruntime.1.dylib`, matching its
Mach-O install ID and the Sherpa load command. CocoaPods copies vendored
libraries by filename and does not create the version alias automatically, so
packaging it only as `libonnxruntime.1.27.0.dylib` produces a launch-time dyld
failure even though linking succeeds.

Run `./tool/sherpa_macos/verify.sh` before using or replacing the artifacts.
The verifier checks hashes, architecture coverage, deployment targets, install
names, and dependencies. The dylibs are unsigned release inputs and the final
application bundle signs them. This package has `publish_to: none`;
the fix must be released by the upstream `sherpa_onnx_macos` owner before
`speech_sherpa` can rely on it from pub.dev.
