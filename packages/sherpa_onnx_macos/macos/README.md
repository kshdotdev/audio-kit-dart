Universal arm64/x86_64 dylibs built for macOS 12.0. Do not replace these files
without running `../../../tool/sherpa_macos/verify.sh` and updating the native
manifest and build provenance.

The ONNX Runtime filename must remain `libonnxruntime.1.dylib`; it matches the
Mach-O install ID consumed by both Sherpa libraries.
