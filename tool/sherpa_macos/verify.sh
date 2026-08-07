#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="$(cd "$script_dir/../.." && pwd)"
package_dir="$workspace_dir/packages/sherpa_onnx_macos"
binary_dir="${1:-$package_dir/macos}"
manifest="$package_dir/native_manifest.sha256"
deployment_target="${SHERPA_MACOS_DEPLOYMENT_TARGET:-12.0}"

readonly dylibs=(
  libonnxruntime.1.dylib
  libsherpa-onnx-c-api.dylib
  libsherpa-onnx-cxx-api.dylib
)

fail() {
  echo "sherpa macOS verification failed: $*" >&2
  exit 1
}

version_is_greater() {
  local lhs_major lhs_minor lhs_patch rhs_major rhs_minor rhs_patch
  IFS=. read -r lhs_major lhs_minor lhs_patch <<<"$1"
  IFS=. read -r rhs_major rhs_minor rhs_patch <<<"$2"
  lhs_minor="${lhs_minor:-0}"
  lhs_patch="${lhs_patch:-0}"
  rhs_minor="${rhs_minor:-0}"
  rhs_patch="${rhs_patch:-0}"

  if ((10#$lhs_major != 10#$rhs_major)); then
    ((10#$lhs_major > 10#$rhs_major))
    return
  fi
  if ((10#$lhs_minor != 10#$rhs_minor)); then
    ((10#$lhs_minor > 10#$rhs_minor))
    return
  fi
  ((10#$lhs_patch > 10#$rhs_patch))
}

[[ "$(uname -s)" == Darwin ]] || fail "this check requires macOS tooling"
for command_name in lipo otool shasum xcrun; do
  command -v "$command_name" >/dev/null || fail "missing $command_name"
done
[[ -d "$binary_dir" ]] || fail "missing binary directory $binary_dir"

if [[ "${SHERPA_MACOS_SKIP_HASH:-0}" != 1 ]]; then
  [[ -f "$manifest" ]] || fail "missing $manifest"
  (
    cd "$binary_dir"
    shasum -a 256 -c "$manifest"
  )
fi

for dylib in "${dylibs[@]}"; do
  file="$binary_dir/$dylib"
  [[ -f "$file" ]] || fail "missing $file"

  archs="$(lipo -archs "$file")"
  [[ " $archs " == *" arm64 "* ]] || fail "$dylib has no arm64 slice"
  [[ " $archs " == *" x86_64 "* ]] || fail "$dylib has no x86_64 slice"
  [[ "$(wc -w <<<"$archs" | tr -d ' ')" == 2 ]] ||
    fail "$dylib has unexpected architectures: $archs"

  case "$dylib" in
    libonnxruntime.1.dylib)
      expected_id='@rpath/libonnxruntime.1.dylib'
      ;;
    libsherpa-onnx-c-api.dylib)
      expected_id='@rpath/libsherpa-onnx-c-api.dylib'
      ;;
    libsherpa-onnx-cxx-api.dylib)
      expected_id='@rpath/libsherpa-onnx-cxx-api.dylib'
      ;;
  esac

  for arch in arm64 x86_64; do
    minos="$(
      xcrun vtool -arch "$arch" -show-build "$file" |
        awk '/minos/{print $2; exit}'
    )"
    [[ -n "$minos" ]] || fail "$dylib/$arch has no macOS build version"
    if version_is_greater "$minos" "$deployment_target"; then
      fail "$dylib/$arch targets macOS $minos (maximum $deployment_target)"
    fi

    install_id="$(otool -arch "$arch" -D "$file" | tail -n 1)"
    [[ "$install_id" == "$expected_id" ]] ||
      fail "$dylib/$arch install ID is $install_id, expected $expected_id"

    while IFS= read -r dependency; do
      dependency="${dependency%% *}"
      case "$dependency" in
        @rpath/* | /System/Library/* | /usr/lib/*) ;;
        *) fail "$dylib/$arch has non-relocatable dependency $dependency" ;;
      esac
    done < <(
      otool -arch "$arch" -L "$file" |
        tail -n +2 |
        sed -E 's/^[[:space:]]+//'
    )
  done
done

for arch in arm64 x86_64; do
  otool -arch "$arch" -L "$binary_dir/libsherpa-onnx-c-api.dylib" |
    grep -Fq '@rpath/libonnxruntime.1.dylib' ||
    fail "Sherpa C API/$arch is not linked to the packaged ONNX Runtime"
  otool -arch "$arch" -L "$binary_dir/libsherpa-onnx-cxx-api.dylib" |
    grep -Fq '@rpath/libsherpa-onnx-c-api.dylib' ||
    fail "Sherpa C++ API/$arch is not linked to the packaged C API"
done

echo "Verified universal sherpa-onnx dylibs for macOS <= $deployment_target."
