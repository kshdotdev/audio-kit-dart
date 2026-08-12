#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$workspace_dir"
dart_bin="$(dirname "$(command -v flutter)")/dart"

readonly package_dirs=(
  packages/audio_core
  packages/audio_flutter_platform_interface
  packages/audio_kit_graph
  packages/audio_processing
  packages/speech_core
  packages/audio_flutter_darwin
  packages/audio_flutter
  packages/voice_core
  packages/speech_deepgram
  packages/speech_openai_tts
  packages/speech_fluidaudio
  packages/speech_sherpa
  packages/speech_mlx
  packages/audio_flutter_linux
  packages/audio_flutter_windows
  packages/audio_aec
  packages/voice_flutter
)

flutter pub get
find packages \
  -path '*/.dart_tool' -prune -o \
  -path '*/build' -prune -o \
  -name '*.dart' ! -name '*.g.dart' -print0 |
  xargs -0 "$dart_bin" format --output=none --set-exit-if-changed
git diff --check

darwin_messages_dart="packages/audio_flutter_darwin/lib/src/messages.g.dart"
darwin_messages_swift="packages/audio_flutter_darwin/darwin/audio_flutter_darwin/Sources/audio_flutter_darwin/Messages.g.swift"
dart_hash_before="$(shasum -a 256 "$darwin_messages_dart")"
swift_hash_before="$(shasum -a 256 "$darwin_messages_swift")"
(
  cd packages/audio_flutter_darwin
  flutter pub run pigeon --input pigeons/audio_flutter.dart
)
dart_hash_after="$(shasum -a 256 "$darwin_messages_dart")"
swift_hash_after="$(shasum -a 256 "$darwin_messages_swift")"
if [[ "$dart_hash_before" != "$dart_hash_after" ||
      "$swift_hash_before" != "$swift_hash_after" ]]; then
  echo "Generated Pigeon files were stale. Regenerate and commit them." >&2
  exit 1
fi

flutter analyze

for package_dir in "${package_dirs[@]}"; do
  if [[ -d "$package_dir/test" ]]; then
    flutter test "$package_dir/test"
  fi
done

# The Darwin plugin's Flutter-free core: the capture supervision windows and
# the sample-rate re-rate math, which no Dart test can reach. Needs a Swift
# toolchain, so it runs on macOS only.
#
# `swift test` builds every target a package declares, and the plugin target
# imports FlutterMacOS, so the manifest narrows itself to the core and its
# XCTest target when AUDIO_FLUTTER_DARWIN_CORE_TESTS is set. Nothing else ever
# sets it; a Flutter build still resolves the plugin library product.
if [[ "$(uname)" == "Darwin" ]]; then
  (
    cd packages/audio_flutter_darwin/darwin/audio_flutter_darwin
    AUDIO_FLUTTER_DARWIN_CORE_TESTS=1 swift test
  )
fi
