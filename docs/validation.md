# Validation

## Default workspace verification

From the Audio Kit workspace:

```sh
cd /Users/kauan/Projects/my/audio-kit-dart
./tool/verify.sh
```

The script resolves packages, runs `flutter analyze`, and runs every package
test directory. These tests cover contract validation, lifecycle races,
fan-out, overflow policies and boundedness, discontinuity ranges, failure
isolation, drain/abort, processing continuity, synchronization/mixing, WAV
finalization, provider fake transports/workers, and voice generation safety.

Also run formatting and whitespace checks before committing:

```sh
dart format --output=none --set-exit-if-changed packages
git diff --check
```

The intended toolchain is Flutter 3.44 with Dart 3.12.

## Verified snapshot

The implementation was last verified on 2026-07-26 with Flutter 3.44.0 and
Dart 3.12.0:

| Scope | Result |
|---|---|
| Audio Kit workspace | `flutter analyze` clean; 211/211 deterministic tests passed |
| Flutter Ectos app | `flutter analyze lib test` clean; 362/362 tests passed |
| Flutter Ectos macOS host | Debug build succeeded and produced `ectos.app` |
| `fluidaudio_dart` | `flutter analyze` clean; 25/25 tests passed |
| `mlx_audio` core package | 204/204 tests passed |
| `mlx_audio` package | 215/215 default tests passed, including 9 explicitly gated real-checkpoint skips |
| Repository hygiene | Dart formatting and changed-file whitespace checks passed |

The Ectos repository contains the copied `references/audio-sdk` research tree
and incomplete plugin examples. A whole-repository analysis therefore reports
issues outside the app target; the verified app gate intentionally scopes
analysis to `lib` and `test`. The macOS build emitted only existing Metal
search-path and future Swift Package Manager migration warnings.

The MLX counts above describe the default suite. The nine skipped tests are not
claimed as real-model passes; use the opt-in commands below on Apple Silicon
with the required checkpoints.

## Focused checks

```sh
flutter test packages/audio_core/test
flutter test packages/audio_kit_graph/test
flutter test packages/audio_processing/test
flutter test packages/audio_flutter/test
flutter test packages/speech_core/test
flutter test packages/speech_fluidaudio/test
flutter test packages/speech_mlx/test
flutter test packages/speech_deepgram/test
flutter test packages/speech_openai_tts/test
flutter test packages/voice_core/test
flutter test packages/voice_flutter/test
```

Provider adapter tests use injected fake runtimes, workers, websocket
transports, HTTP transports, and token sources unless an integration command
explicitly says otherwise. Passing them proves the adapter contract and
lifecycle, not the availability of a remote service or local model checkpoint.

## Ectos application

The migrated app is a concrete macOS host for the federated plugin and graph
composition:

```sh
cd /Users/kauan/Projects/my/flutter-app
flutter pub get
flutter analyze lib test
flutter test
flutter build macos --debug
```

The build checks native macOS registration and compilation. Tests should cover
the graph-backed provider defaults, selected input device, custom vocabulary,
process targeting, recording paths, startup ordering, and failure cleanup.

An iOS host that path-depends on `audio_flutter` should also run:

```sh
flutter build ios --simulator --no-codesign
```

This is a compile check for the shared Darwin plugin. It does not exercise
microphone permission, devices, playback timing, or any macOS-only process tap.

## Inference-engine repositories

FluidAudio:

```sh
cd /Users/kauan/Projects/my/fluidaudio-dart
flutter pub get
flutter analyze
flutter test
```

MLX Audio:

```sh
cd /Users/kauan/Projects/my/mlx-audio
make setup
dart analyze
make test
```

These default commands do not imply that large real-model suites ran.

## Opt-in real integration

Real FluidAudio inference requires a macOS device and model assets:

```sh
cd /Users/kauan/Projects/my/fluidaudio-dart/example
flutter test integration_test/plugin_integration_test.dart -d macos
FLUIDAUDIO_RUN_MODELS=1 \
  flutter test integration_test/real_models_test.dart -d macos
```

MLX checkpoint tests are tagged and skipped by default because they may
download large assets and require Apple Silicon:

```sh
cd /Users/kauan/Projects/my/mlx-audio/packages/mlx_audio
dart test -t e2e --run-skipped
dart test -t weights --run-skipped
```

Deepgram and OpenAI adapter tests do not call production endpoints. A real
cloud smoke test must inject renewable credentials, use a non-sensitive audio
fixture, verify cancellation and finalization, and avoid logging token values.

## Long-running and hardware acceptance

Before publishing or broad deployment, run hardware tests that are deliberately
outside the deterministic default suite:

- simultaneous microphone and macOS system capture;
- selected-device changes and permission denial/recovery;
- process targeting and one-shot silent-tap rebuild;
- one capture feeding STT, VAD/EOU, WAV, and metering concurrently;
- long-running capture with route and native mailbox high-water monitoring;
- fail-capture recording overflow and valid WAV finalization on every stop or
  failure path;
- Deepgram/OpenAI disconnect, token renewal, and cancellation;
- MLX UI-isolate responsiveness, worker replacement after cancellation, and
  real incremental TTS timing;
- VAD barge-in while output is active and a cancellation-insensitive backend is
  still unwinding.

Record the exact command, hardware/OS, model IDs, credentials environment, test
duration, and result when these opt-in checks are run. Do not treat a gated skip
as a passing real-model result.
