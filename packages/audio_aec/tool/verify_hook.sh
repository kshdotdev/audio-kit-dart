#!/usr/bin/env bash
#
# Exercises `hook/build.dart`'s download strategy end to end, including the
# case that matters most: a hash that does not match must produce NO asset.
#
# The example/ package covers the `prebuilt` (local file) strategy because that
# one is relocatable enough to commit. The URL strategy needs an absolute URL
# and a hash of a file that is gitignored, so it lives here instead of in a
# checked-in pubspec.
#
# Uses a file:// URL against the output of build_native.sh. That exercises every
# step a real https:// fetch does except the socket: plan the URL, fetch bytes,
# hash them, compare against the pin, install, register. Only the transport
# differs, and the transport is `HttpClient` in the same function.
#
# Usage:
#   packages/audio_aec/tool/build_native.sh   # once
#   packages/audio_aec/tool/verify_hook.sh
set -euo pipefail

PKG_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$PKG_ROOT/example"
PUBSPEC="$EXAMPLE/pubspec.yaml"

case "$(uname -s)" in
  Darwin) LIB="libaec_ffi.dylib" ;;
  Linux)  LIB="libaec_ffi.so" ;;
  *) echo "verify_hook.sh: unsupported platform $(uname -s)." >&2; exit 0 ;;
esac

ARTIFACT="$PKG_ROOT/.native/$LIB"
if [ ! -f "$ARTIFACT" ]; then
  echo "Error: $ARTIFACT not found. Run tool/build_native.sh first." >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  SHA="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"
else
  SHA="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
fi
URL="file://$ARTIFACT"

BACKUP="$(mktemp)"
cp "$PUBSPEC" "$BACKUP"
# Always put the committed pubspec back, including on failure: leaving a
# machine-specific absolute URL in a tracked file would be a nasty surprise.
restore() { cp "$BACKUP" "$PUBSPEC"; rm -f "$BACKUP"; }
trap restore EXIT

# Rewrites the user-defines block, keeping everything above it.
write_defines() { # url sha
  python3 - "$PUBSPEC" "$1" "$2" <<'PY'
import sys
path, url, sha = sys.argv[1], sys.argv[2], sys.argv[3]
head = open(path).read().split('\nhooks:\n')[0].rstrip()
open(path, 'w').write(
    head + '\n\nhooks:\n  user_defines:\n    audio_aec:\n'
    f'      prebuilt_url: {url}\n      prebuilt_sha256: {sha}\n')
PY
}

run_case() { # label expect_pass
  echo
  echo "=== $1 ==="
  # The hook is cached on its inputs; the pubspec edit changes them, but drop
  # the downloaded copy too so the fetch actually re-runs.
  rm -rf "$EXAMPLE/.dart_tool/hooks_runner" 2>/dev/null || true
  set +e
  ( cd "$EXAMPLE" && env -u AUDIO_AEC_LIBRARY dart test 2>&1 )
  local status=$?
  set -e
  if [ "$2" = pass ] && [ $status -ne 0 ]; then
    echo "FAIL: expected the suite to pass." >&2; exit 1
  fi
  if [ "$2" = skip ] && [ $status -ne 0 ]; then
    echo "FAIL: a rejected download must SKIP (no asset), not error." >&2; exit 1
  fi
}

( cd "$EXAMPLE" && dart pub get >/dev/null )

write_defines "$URL" "$SHA"
run_case "Correct sha256 -> asset registered, suite runs" pass

# Deliberately hex-with-letters: an all-digit scalar is typed by YAML as an
# integer, which is a different code path in the hook (and was a bug there).
write_defines "$URL" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
run_case "Wrong sha256 -> download refused, no asset, suite SKIPS" skip

echo
echo "=== Both cases behaved as specified. ==="
