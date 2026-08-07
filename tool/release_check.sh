#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <package-name> <working-directory>" >&2
  exit 64
fi

workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$workspace_dir"
dart_bin="$(dirname "$(command -v flutter)")/dart"

package_name="$1"
package_dir="$2"
manifest="$package_dir/pubspec.yaml"

if [[ ! -f "$manifest" || "$package_dir" != packages/* ]]; then
  echo "Invalid package directory: $package_dir" >&2
  exit 64
fi

manifest_name="$(sed -n 's/^name:[[:space:]]*//p' "$manifest" | head -1)"
manifest_version="$(sed -n 's/^version:[[:space:]]*//p' "$manifest" | head -1)"
if [[ "$manifest_name" != "$package_name" || -z "$manifest_version" ]]; then
  echo "Workflow package metadata does not match $manifest" >&2
  exit 65
fi

expected_tag="${package_name}-v${manifest_version}"
if [[ "${GITHUB_REF_NAME:-}" != "$expected_tag" ]]; then
  echo "Expected tag $expected_tag, got ${GITHUB_REF_NAME:-<unset>}" >&2
  exit 65
fi

flutter pub get
find "$package_dir" \
  -path '*/.dart_tool' -prune -o \
  -path '*/build' -prune -o \
  -name '*.dart' ! -name '*.g.dart' -print0 |
  xargs -0 "$dart_bin" format --output=none --set-exit-if-changed
(
  cd "$package_dir"
  flutter pub publish --dry-run
)

# Workspace resolution intentionally selects sibling packages. Copying the
# selected package out of the workspace proves every hosted constraint is
# independently consumable before the OIDC publishing job starts.
standalone_dir="$(mktemp -d)"
# ./example is excluded from the copy: with its workspace marker stripped it
# resolves as a standalone project depending on the very version this run is
# about to publish — unresolvable by construction. The published archive
# still ships example/ from the real tree; the standalone proof is about the
# PACKAGE's hosted constraints.
tar \
  --exclude=.dart_tool \
  --exclude=build \
  --exclude=./example \
  -C "$package_dir" \
  -cf - . | tar -C "$standalone_dir" -xf -
# Strip the workspace marker from EVERY copied pubspec, not just the root:
# a nested example that is itself a workspace member (audio_flutter/example)
# otherwise makes the standalone `pub get` fail with "found no workspace
# root including it in parent directories".
find "$standalone_dir" -name pubspec.yaml \
  -exec sed -i.bak '/^resolution:[[:space:]]*workspace[[:space:]]*$/d' {} +
"$dart_bin" pub -C "$standalone_dir" get
