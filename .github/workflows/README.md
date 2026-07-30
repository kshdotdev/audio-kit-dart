# Workflows

`ci.yml` is the pull-request gate. `publish-*.yml` are tag-triggered and are
the only workflows that hold publishing credentials; nothing in `ci.yml` may
grow a publish step.

## Jobs in ci.yml

| Job | Runner | What only this job can prove |
|---|---|---|
| `verify` | `ubuntu-latest` | `tool/verify.sh` + publish dry runs (pre-existing) |
| `windows-desktop` | `windows-latest` | `audio_flutter_windows`' WASAPI C++ compiles and links |
| `linux-desktop` | `ubuntu-latest` | The example links against GTK and the Linux registrant resolves |
| `macos-desktop` | `macos-latest` | `audio_flutter_darwin`'s Swift package compiles under xcodebuild |
| `linux-pulse-capture` | `ubuntu-latest` | Real capture against a live PulseAudio server — **manual only** |

All four desktop jobs build `packages/audio_flutter/example`. That app is the
only place where the native halves of the federated plugin are compiled at all;
no unit test reaches them.

### Expect windows-desktop to fail first

`packages/audio_flutter_windows/windows/*.cpp` was written on macOS against the
Windows SDK headers by reference and has never been through a compiler. Its
`windows/README.md` lists the porting mistakes to expect, in order of
likelihood. The job is separate and named so that "the C++ does not compile"
never hides inside a generic build failure.

## Why linux-pulse-capture is behind workflow_dispatch

`audio_flutter_linux` shells out to `parecord`/`pw-record` and parses their
stdout. Its unit suite mocks that process seam, so the argument strings and the
raw-PCM framing are unverified against a real sound server. The
`linux-pulse-capture` job closes that gap: it loads a null sink, captures from
its monitor, and asserts frames arrive at the expected cadence.

It is **not** on the pull-request path, and the honest reason is that its
stability is unproven rather than proven:

1. It has never been executed. It was designed on macOS, where PulseAudio does
   not exist, so no amount of local checking establishes that the daemon comes
   up on a headless runner.
2. A hosted runner has no sound daemon configured and no D-Bus session. Getting
   `pulseaudio --start` to survive there depends on `XDG_RUNTIME_DIR`,
   autospawn settings, and the image's PulseAudio-vs-PipeWire packaging — the
   historically flakiest part of audio CI.
3. Ubuntu is migrating off PulseAudio. An image rollout can change the
   `pulseaudio` package's behaviour without any change to this repository,
   which would turn a required check red for reasons unrelated to the code.

A required check that goes red for infrastructure reasons trains people to
ignore it, and this particular check is too valuable to be ignored. So it runs
on demand:

```
gh workflow run ci.yml -f run_pulse_integration=true
```

When it is dispatched it is a hard gate — no `continue-on-error`, no tolerated
skips. Promote it to the pull-request path once it has run green several times
in a row on the current runner image; that is the only evidence that would
justify the change.

The same script is runnable by hand on any Linux box:

```sh
cd packages/audio_flutter/example
pactl load-module module-null-sink sink_name=ci_sink
dart run tool/pulse_capture_smoke.dart --source ci_sink.monitor --seconds 2
```

## Caching

Every job uses `flutter-actions/setup-flutter` with `cache: true` and
`cache-sdk: true`, matching `verify`. Native build outputs (the Windows CMake
tree, the macOS DerivedData tree) are not cached: a first-compile job that
reuses object files is not proving what it claims to prove.
