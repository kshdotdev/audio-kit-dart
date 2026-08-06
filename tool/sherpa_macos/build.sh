#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="$(cd "$script_dir/../.." && pwd)"
package_dir="$workspace_dir/packages/sherpa_onnx_macos"

readonly onnxruntime_version=1.27.0
readonly onnxruntime_commit=8f0278c77bf44b0cc83c098c6c722b92a36ac4b5
readonly sherpa_version=1.13.4
readonly sherpa_commit=142807252687d81b40d6315f23470a1512a00de3
readonly deployment_target=12.0

fail() {
  echo "sherpa macOS build failed: $*" >&2
  exit 1
}

[[ "$(uname -s)" == Darwin ]] || fail "this build requires macOS"
for command_name in cmake git ninja python3 xcrun; do
  command -v "$command_name" >/dev/null || fail "missing $command_name"
done

python_bin="${SHERPA_MACOS_PYTHON:-$(command -v python3)}"
python_version="$($python_bin -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
python_major="${python_version%%.*}"
python_minor="${python_version#*.}"
if ((python_major < 3 || (python_major == 3 && python_minor < 10))); then
  fail "ONNX Runtime requires Python 3.10 or newer (found $python_version)"
fi

build_root="${SHERPA_MACOS_BUILD_ROOT:-$(mktemp -d -t audio-kit-sherpa-macos.XXXXXX)}"
if [[ -z "${SHERPA_MACOS_BUILD_ROOT:-}" ]]; then
  trap 'rm -rf "$build_root"' EXIT
fi
mkdir -p "$build_root"

jobs="${SHERPA_MACOS_BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}"
onnx_source="$build_root/onnxruntime"
onnx_build="$build_root/onnx-build"
onnx_install="$build_root/onnx-install"
sherpa_source="$build_root/sherpa-onnx"
sherpa_build="$build_root/sherpa-build"
sherpa_install="$build_root/sherpa-install"
output_dir="${SHERPA_MACOS_OUTPUT_DIR:-$workspace_dir/build/sherpa_macos}"

git clone --branch "v$onnxruntime_version" --depth 1 --recursive \
  --shallow-submodules https://github.com/microsoft/onnxruntime.git \
  "$onnx_source"
[[ "$(git -C "$onnx_source" rev-parse HEAD)" == "$onnxruntime_commit" ]] ||
  fail "ONNX Runtime tag resolved to an unexpected commit"

(
  cd "$onnx_source"
  "$python_bin" tools/ci_build/build.py \
    --build_dir "$onnx_build" \
    --config Release \
    --cmake_generator Ninja \
    --update \
    --build \
    --build_shared_lib \
    --compile_no_warning_as_error \
    --cmake_extra_defines \
      onnxruntime_BUILD_UNIT_TESTS=OFF \
      "CMAKE_INSTALL_PREFIX=$onnx_install" \
      'CMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
      "CMAKE_OSX_DEPLOYMENT_TARGET=$deployment_target" \
      CMAKE_POLICY_VERSION_MINIMUM=3.5 \
      FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER \
      CMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
      CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    --apple_sysroot macosx \
    --target install \
    --parallel "$jobs" \
    --skip_tests \
    --apple_deploy_target "$deployment_target" \
    --no_kleidiai \
    --use_coreml
)

git clone --branch "v$sherpa_version" --depth 1 \
  https://github.com/k2-fsa/sherpa-onnx.git "$sherpa_source"
[[ "$(git -C "$sherpa_source" rev-parse HEAD)" == "$sherpa_commit" ]] ||
  fail "sherpa-onnx tag resolved to an unexpected commit"

export SHERPA_ONNXRUNTIME_LIB_DIR="$onnx_install/lib"
export SHERPA_ONNXRUNTIME_INCLUDE_DIR="$onnx_install/include/onnxruntime"
cmake -S "$sherpa_source" -B "$sherpa_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
  -DCMAKE_INSTALL_PREFIX="$sherpa_install" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=ON \
  -DSHERPA_ONNX_ENABLE_BINARY=OFF \
  -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
  -DSHERPA_ONNX_ENABLE_TTS=ON \
  -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF
cmake --build "$sherpa_build" --target install --parallel "$jobs"

mkdir -p "$output_dir"
install -m 0644 \
  "$sherpa_install/lib/libonnxruntime.1.27.0.dylib" \
  "$output_dir/libonnxruntime.1.dylib"
for dylib in \
  libsherpa-onnx-c-api.dylib \
  libsherpa-onnx-cxx-api.dylib; do
  install -m 0644 "$sherpa_install/lib/$dylib" "$output_dir/$dylib"
done

SHERPA_MACOS_SKIP_HASH=1 "$script_dir/verify.sh" "$output_dir"
shasum -a 256 "$output_dir"/*.dylib

echo "Build output: $output_dir"
echo "Review the hashes, then copy the three dylibs into $package_dir/macos"
echo "and update $package_dir/native_manifest.sha256 in the same change."
