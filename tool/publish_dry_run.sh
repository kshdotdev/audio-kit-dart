#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$workspace_dir"

# Keep this topologically sorted. Hosted dependencies from an earlier tier must
# be live before a later package can be published for the first time.
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
  packages/speech_mlx
  packages/voice_flutter
)

for package_dir in "${package_dirs[@]}"; do
  echo "Dry-running ${package_dir#packages/}"
  (
    cd "$package_dir"
    flutter pub publish --dry-run
  )
done
