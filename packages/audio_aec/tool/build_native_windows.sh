#!/usr/bin/env bash
#
# Builds the x64 Windows WebRTC AEC3 shim with MSVC. Run from Git Bash after an
# MSVC developer environment has been exported (the release workflow uses
# ilammy/msvc-dev-cmd). The source revision is shared with build_native.sh via
# native_release.env; no source or binary is downloaded from an unpinned ref.
set -euo pipefail

PKG_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$PKG_ROOT/native/aec_ffi.cc"
DEST="${1:-$PKG_ROOT/.native}"

# Resolved from this script's absolute package root.
# shellcheck disable=SC1091
source "$PKG_ROOT/tool/native_release.env"
WAP_REPO="${WAP_REPO:-$AUDIO_AEC_WAP_REPO}"
WAP_REF="${WAP_REF:-$AUDIO_AEC_WAP_REF}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"
}

git_clone_pinned() {
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
  MINGW*|MSYS*|CYGWIN*) ;;
  *) die "build_native_windows.sh must run under Git Bash on Windows." ;;
esac

require_cmd git "Install Git for Windows."
require_cmd meson "Install it with 'python -m pip install meson ninja'."
require_cmd ninja "Install it with 'python -m pip install meson ninja'."
require_cmd cl "Run from an x64 MSVC developer environment."
require_cmd link "Run from an x64 MSVC developer environment."
require_cmd dumpbin "Run from an x64 MSVC developer environment."
require_cmd cygpath "Use Git Bash, MSYS2, or Cygwin."
[ -f "$SHIM" ] || die "shim source not found: $SHIM"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Cloning $WAP_REPO @ $WAP_REF"
git_clone_pinned "$WAP_REPO" "$WAP_REF" "$WORK/wap"
SRC="$WORK/wap"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$SRC" show -s --format=%ct HEAD)}"
export SOURCE_DATE_EPOCH

log "Configuring webrtc-audio-processing for static MSVC linkage"
( cd "$SRC" && meson setup build --vsenv \
    --buildtype=release \
    --default-library=static \
    -Db_vscrt=mt \
    --force-fallback-for=abseil-cpp >/dev/null )

# As on macOS, the upstream example target can fail after every archive needed
# by the shim has been built. The archive and final runtime probes below are the
# hard gates; an incomplete build cannot be staged.
log "Building static archives"
( cd "$SRC" && ninja -C build ) || true

MAIN_LIB="$(find "$SRC/build" -name 'webrtc-audio-processing-2.lib' | head -1 || true)"
[ -n "$MAIN_LIB" ] || die "APM static library was not built."
ABSEIL_INC="$(find "$SRC/subprojects" -maxdepth 1 -type d -name 'abseil-cpp-*' | head -1 || true)"
[ -n "$ABSEIL_INC" ] || die "bundled Abseil source was not unpacked."

log "Compiling the AEC C ABI with reproducible MSVC object metadata"
cl //nologo //std:c++17 //O2 //MT //Brepro \
  //DWEBRTC_WIN //DWEBRTC_APM_DEBUG_DUMP=0 \
  //pathmap:"$(cygpath -w "$WORK")"=C:\\src\\audio_aec \
  //I "$(cygpath -w "$SRC/webrtc")" \
  //I "$(cygpath -w "$ABSEIL_INC")" \
  //c "$(cygpath -w "$SHIM")" \
  //Fo"$(cygpath -w "$WORK/aec_ffi.obj")"

OTHER_LIBS=()
while IFS= read -r library; do
  [ "$library" = "$MAIN_LIB" ] || OTHER_LIBS+=("$(cygpath -w "$library")")
done < <(find "$SRC/build" -name '*.lib' | sort)

mkdir -p "$DEST"
OUTPUT="$(cygpath -w "$DEST/aec_ffi.dll")"
log "Linking aec_ffi.dll and exporting the six stable ABI symbols"
link //nologo //DLL //Brepro //OUT:"$OUTPUT" \
  "$(cygpath -w "$WORK/aec_ffi.obj")" \
  //WHOLEARCHIVE:"$(cygpath -w "$MAIN_LIB")" \
  "${OTHER_LIBS[@]}" \
  //EXPORT:aec_create \
  //EXPORT:aec_process_reverse \
  //EXPORT:aec_process_capture \
  //EXPORT:aec_get_metrics \
  //EXPORT:aec_destroy \
  //EXPORT:aec_version

[ -f "$DEST/aec_ffi.dll" ] || die "link.exe produced no aec_ffi.dll."
EXPORTS="$(dumpbin //nologo //exports "$OUTPUT")" || die "dumpbin failed."
for symbol in aec_create aec_process_reverse aec_process_capture aec_get_metrics aec_destroy aec_version; do
  grep -qw "$symbol" <<<"$EXPORTS" || die "aec_ffi.dll is missing export $symbol."
done
log "Done. Installed $DEST/aec_ffi.dll."
