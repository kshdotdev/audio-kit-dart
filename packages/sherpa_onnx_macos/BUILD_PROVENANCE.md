# Native build provenance

The three dylibs in `macos/` were built from unmodified upstream sources:

- ONNX Runtime 1.27.0, commit
  `8f0278c77bf44b0cc83c098c6c722b92a36ac4b5`.
- sherpa-onnx 1.13.4, commit
  `142807252687d81b40d6315f23470a1512a00de3`.

Build properties:

- architectures: `arm64;x86_64`;
- deployment target: macOS 12.0;
- ONNX Runtime shared library with CPU and CoreML execution providers;
- ONNX Runtime packaged under its `@rpath/libonnxruntime.1.dylib` install name;
- full sherpa-onnx shared C/C++ APIs, including transcription, VAD,
  diarization, speaker embeddings, and TTS;
- unit tests, examples, command-line binaries, PortAudio, WebSocket, Python,
  and JNI targets excluded from the binary package;
- fetched/pinned Protobuf used by forcing CMake FetchContent package lookup,
  preventing an incompatible Homebrew Protobuf from leaking into the build.

The checked-in revision was produced with Xcode 26.0.1 (AppleClang 17.0.0),
CMake 4.2.2, Ninja 1.13.2, and Python 3.14.6. The build script pins source
revisions and build options; output hashes can still change with a different
Apple linker/toolchain and must be reviewed and recorded explicitly.

Artifact SHA-256 values are stored in `native_manifest.sha256`. ONNX Runtime
is MIT licensed; sherpa-onnx is Apache-2.0 licensed. Their licenses are
included as `LICENSE.onnxruntime` and `LICENSE` respectively.
