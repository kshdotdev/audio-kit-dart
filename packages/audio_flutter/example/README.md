# audio_flutter_example

A deliberately small desktop host for `audio_flutter`. Its job is to be
**compiled**, not demonstrated: building it on each desktop platform is what
forces every federated implementation — including native code that no unit test
can reach — through a real toolchain.

| Platform | Implementation compiled | What the build proves |
|---|---|---|
| macOS | `audio_flutter_darwin` | Swift plugin registers and links |
| Windows | `audio_flutter_windows` | WASAPI C++ compiles and links (`Mmdevapi`, `Ole32`, `Avrt`, `Propsys`) |
| Linux | `audio_flutter_linux` | Dart-only registrant resolves; GTK shell links |

`packages/audio_flutter/example/.flutter-plugins-dependencies` after
`flutter pub get` is the quickest confirmation that all three resolve.

## Windows is a direct dependency on purpose

`audio_flutter` endorses Darwin and Linux in its `flutter.plugin.platforms`
map, but not Windows. An unendorsed federated implementation is only pulled
into an app build when the app depends on it **directly**, so this example
lists `audio_flutter_windows` in `dependencies` rather than relying on
`audio_flutter` to bring it in. Remove that line and `flutter build windows`
silently stops compiling the C++, which is the whole point of the CI job.

If `audio_flutter` later endorses Windows, this direct dependency becomes
redundant and can be dropped.

## Workspace membership

The example is a member of the root pub workspace (`resolution: workspace`, and
listed under `workspace:` in the root `pubspec.yaml`). A single
`flutter pub get` at the repository root resolves it along with every package,
and its sibling dependencies resolve to the local sources rather than pub.dev.
No `dependency_overrides` and no path dependencies are needed.

## Running it

```sh
flutter run -d macos      # or -d windows, -d linux
```

Three buttons:

* **List devices** — `FlutterAudioDevices.listInputs()`.
* **Start capture** — prepares and starts a 48 kHz mono capture, counting
  frames and showing the running peak.
* **Stop capture** — graceful `stop()` then `close()`.

The segmented control switches between microphone and system-audio capture.
System audio is the loopback path on Windows and a sink monitor on Linux.

## Linux real-server smoke test

`tool/pulse_capture_smoke.dart` opens a genuine capture against a PulseAudio
monitor source and asserts frames arrive. It is a plain Dart entrypoint —
nothing in `audio_flutter_linux` imports `dart:ui` — so it runs without a
display or a Flutter engine:

```sh
pactl load-module module-null-sink sink_name=ci_sink
dart run tool/pulse_capture_smoke.dart --source ci_sink.monitor --seconds 2
```

It exits non-zero when no capture tool is installed, when the requested monitor
is missing, when the session fails, or when fewer than half the nominal frames
arrive. This is the only check that exercises the real `parecord` argument
strings; the package's unit suite mocks the process seam.
