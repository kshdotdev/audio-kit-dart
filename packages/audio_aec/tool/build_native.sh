#!/usr/bin/env bash
#
# Adapted from Control Center's `scripts/natives/build_aec.sh` (and the helpers
# it sources from `scripts/natives/lib/natives_common.sh`).
# Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.
#
# Adaptation notes:
#   - Self-contained: the original sources a shared `natives_common.sh` used by
#     five native builds; audio_aec has exactly one, so the three helpers it
#     actually needs (log/die, pinned clone, ad-hoc sign) are inlined.
#   - Install destination is the package-local, GITIGNORED `.native/` directory
#     instead of the app-support root. This package is a library, not an app: it
#     has no bundle to install into, and the loader (lib/src/bindings.dart)
#     resolves an explicit path or $AUDIO_AEC_LIBRARY rather than a data dir.
#   - The upstream repository and pinned revision are unchanged, so the produced
#     ABI matches the shim in native/aec_ffi.cc symbol-for-symbol.
#
# Builds libaec_ffi — a thin C ABI (native/aec_ffi.cc) over WebRTC's AEC3
# AudioProcessing module — from webrtc-audio-processing at a pinned revision.
# No WebRTC source is vendored into this repository; it is fetched here.
#
# abseil is statically linked from the meson wrap (NOT a system/Homebrew shared
# abseil) so the result is self-contained and relocatable.
#
# STATUS: the macOS (arm64) path is exercised. The Linux path is carried over
# from the original unchanged and is UNTESTED here. Windows is not covered at
# all — the original builds it separately with MSVC.
#
# Requirements: git, meson, ninja, pkg-config, a C++ compiler (c++).
#
# Usage:
#   packages/audio_aec/tool/build_native.sh [DEST_DIR]
#   WAP_REF=<sha> packages/audio_aec/tool/build_native.sh
#
# DEST_DIR defaults to <package>/.native. Point the loader at the result with:
#   export AUDIO_AEC_LIBRARY="$(pwd)/packages/audio_aec/.native/libaec_ffi.dylib"
set -euo pipefail

PKG_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$PKG_ROOT/native/aec_ffi.cc"
DEST="${1:-$PKG_ROOT/.native}"

WAP_REPO="${WAP_REPO:-https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git}"
WAP_REF="${WAP_REF:-d0569cfa50c1858ee279d77b3fc8870be6902441}" # v2.1

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

require_cmd() { # cmd hint
  command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"
}

# Shallow-clone a single pinned commit; falls back to a full fetch + checkout if
# the server rejects a shallow SHA fetch.
git_clone_pinned() { # repo ref dest
  git init -q "$3"
  git -C "$3" remote add origin "$1"
  if git -C "$3" fetch -q --depth 1 origin "$2" 2>/dev/null; then
    git -C "$3" -c advice.detachedHead=false checkout -q FETCH_HEAD
  else
    git -C "$3" fetch -q origin
    git -C "$3" -c advice.detachedHead=false checkout -q "$2"
  fi
}

case "$(uname -s)" in
  Darwin) NATIVE_OS=Darwin; NATIVE_EXT=dylib ;;
  Linux)  NATIVE_OS=Linux;  NATIVE_EXT=so ;;
  *)
    warn "build_native.sh: unsupported platform $(uname -s). Build the library with an MSVC toolchain and point AUDIO_AEC_LIBRARY at it."
    exit 0 ;;
esac

require_cmd git "Install Xcode Command Line Tools (macOS) or your package manager's git."
require_cmd meson "Install via 'brew install meson' (macOS) or 'pip install meson' (Linux)."
require_cmd ninja "Install via 'brew install ninja' (macOS) or 'apt install ninja-build' (Linux)."
require_cmd pkg-config "Install via 'brew install pkg-config' (macOS) or 'apt install pkg-config' (Linux)."
CXX="${CXX:-c++}"
require_cmd "$CXX" "Install a C++ toolchain (Xcode CLT on macOS, build-essential on Linux) and re-run."
[ -f "$SHIM" ] || die "shim source not found: $SHIM"

LIB="libaec_ffi.$NATIVE_EXT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Cloning $WAP_REPO @ $WAP_REF"
git_clone_pinned "$WAP_REPO" "$WAP_REF" "$WORK/wap"
SRC="$WORK/wap"

log "Configuring webrtc-audio-processing (static lib, AEC3, bundled static abseil)"
( cd "$SRC" && meson setup build \
    --buildtype=release \
    --default-library=static \
    --force-fallback-for=abseil-cpp >/dev/null )

# Build all static archives. The 'examples/run-offline' target's link fails on
# macOS (upstream omits CoreFoundation/Foundation from its link line); that is
# the LAST target and every archive needed here is already built by then, so the
# failure is expected and ignored.
log "Building static archives (the example target's link is expected to fail on macOS — ignored)"
( cd "$SRC" && ninja -C build || true )

MAIN_AR="$SRC/build/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a"
[ -f "$MAIN_AR" ] || die "APM static archive not built: $MAIN_AR (check the meson/ninja output above)"

ABSEIL_INC="$(find "$SRC/subprojects" -maxdepth 1 -type d -name 'abseil-cpp-*' | head -1)"
[ -n "$ABSEIL_INC" ] || die "abseil subproject not unpacked under $SRC/subprojects (force-fallback failed?)"

if [ "$NATIVE_OS" = "Darwin" ]; then
  OS_DEFINE="-DWEBRTC_MAC"
else
  OS_DEFINE="-DWEBRTC_LINUX"
fi

log "Compiling shim ($SHIM) for $NATIVE_OS"
"$CXX" -std=c++17 -O2 -fPIC \
  -DWEBRTC_POSIX "$OS_DEFINE" -DWEBRTC_APM_DEBUG_DUMP=0 \
  -Wno-nullability-completeness \
  -I "$SRC/webrtc" -I "$ABSEIL_INC" \
  -c "$SHIM" -o "$WORK/aec_ffi.o"

# Whole-archive the main APM archive so every AEC3 object is present (some are
# only reached via internal wiring); normal-load the deps + static abseil (only
# referenced objects pulled).
OTHER_ARCHIVES=()
while IFS= read -r a; do
  [ "$a" = "$MAIN_AR" ] || OTHER_ARCHIVES+=("$a")
done < <(find "$SRC/build" -name '*.a')

if [ "$NATIVE_OS" = "Darwin" ]; then
  log "Linking $LIB (force_load APM + ${#OTHER_ARCHIVES[@]} dep/abseil archives + CoreFoundation/Foundation)"
  "$CXX" -dynamiclib -o "$WORK/$LIB" "$WORK/aec_ffi.o" \
    -Wl,-force_load,"$MAIN_AR" \
    "${OTHER_ARCHIVES[@]}" \
    -framework CoreFoundation -framework Foundation \
    -install_name "@rpath/$LIB"
else
  # GNU ld: --whole-archive is the force_load equivalent and is order-sensitive,
  # so the deps follow inside the no-whole-archive section.
  log "Linking $LIB (--whole-archive APM + ${#OTHER_ARCHIVES[@]} dep/abseil archives)"
  "$CXX" -shared -o "$WORK/$LIB" "$WORK/aec_ffi.o" \
    -Wl,--whole-archive "$MAIN_AR" -Wl,--no-whole-archive \
    "${OTHER_ARCHIVES[@]}" \
    -Wl,-soname,"$LIB" \
    -lpthread -lm
fi

# Sanity: confirm the C symbols are exported and there are no system-abseil
# runtime deps (the library must be self-contained).
if [ "$NATIVE_OS" = "Darwin" ]; then
  nm -gU "$WORK/$LIB" | grep -q "_aec_create" || die "built $LIB is missing the aec_create symbol"
  if otool -L "$WORK/$LIB" | grep -qi "Cellar/abseil\|/abseil"; then
    warn "WARNING: $LIB links a non-bundled abseil — not self-contained:"
    otool -L "$WORK/$LIB" | grep -i abseil >&2 || true
  fi
else
  nm -D "$WORK/$LIB" | grep -q " aec_create" || die "built $LIB is missing the aec_create symbol"
  if ldd "$WORK/$LIB" 2>/dev/null | grep -qi "abseil"; then
    warn "WARNING: $LIB links a system abseil — not self-contained:"
    ldd "$WORK/$LIB" | grep -i abseil >&2 || true
  fi
fi

mkdir -p "$DEST"
cp -f "$WORK/$LIB" "$DEST/$LIB"

# Ad-hoc sign so the library loads under the local Hardened Runtime. This is NOT
# distribution signing: a redistributed dylib needs a Developer ID identity and
# notarization, which is one of the open questions in risk R4 (see README).
if [ "$NATIVE_OS" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --timestamp=none "$DEST/$LIB" >/dev/null 2>&1 ||
    warn "codesign failed for $DEST/$LIB (the library may still load locally)"
fi

log "Done. Installed $DEST/$LIB ($(du -h "$DEST/$LIB" | cut -f1))."
log "Point the loader at it:  export AUDIO_AEC_LIBRARY=\"$DEST/$LIB\""
