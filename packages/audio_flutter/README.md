# audio_flutter

Provider-neutral Flutter microphone capture, system/process capture, device
discovery, microphone and system-audio permissions, health events, PCM
playback, and native WAV recording.

```dart
import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter/audio_flutter.dart';

final source = FlutterAudioCaptureSource(
  FlutterAudioCaptureConfig(
    type: AudioCaptureType.microphone,
    format: AudioFormat(sampleRate: 16000, channels: 1),
  ),
);

final session = await source.prepare();
final frames = session.frames.listen(routeFrame);
await session.start();
```

Subscribe and attach routes before `start()` so early frames and health events
cannot be lost. Use `audio_kit_graph` when one capture must feed multiple
independent consumers.

The first implementation supports Apple platforms. System/process capture is
macOS-only.

## Microphone permission

`prepare()` fails a microphone capture with the typed
`microphone_permission_denied` failure when access is denied or restricted,
instead of starting an engine that would deliver only zeroes. Query or request
the permission yourself when the app wants to explain the prompt first:

```dart
final permission = FlutterMicrophonePermission();
var status = await permission.status();
if (status == AudioMicrophonePermissionStatus.notDetermined) {
  status = await permission.request();
}
if (status.blocksCapture) {
  // Only the user can lift this, in system settings.
}
```

A platform with no permission gate reports
`AudioMicrophonePermissionStatus.unavailable` and is never blocked. Apple
platforms still require the host app's `Info.plist` microphone usage
description; without it the process is terminated before any of this runs.

## Selecting the processes to tap

Tapping a meeting app by its main process ID captures nothing: Electron and
Chromium apps render audio in helper processes, and browsers render web-call
audio in shared engine processes under a different bundle namespace.
`SystemAudioProcessSelector` expands a target set over a process snapshot.

```dart
final systemAudio = FlutterSystemAudio();
final processes = await systemAudio.listProcesses();
final processIds = const SystemAudioProcessSelector().expandProcessIds(
  processes: processes,
  bundleIds: <String>['com.microsoft.teams2', 'com.apple.Safari'],
);

final config = FlutterAudioCaptureConfig(
  type: AudioCaptureType.systemAudio,
  format: format,
  processIds: processIds,
);
```

The prefix tables (`browserExternalMediaBundlePrefixes`, `teamsBundlePrefixes`,
`electronHelperBundleSuffixes`, ...) are public const and can be replaced
through the constructor, so an app can teach the selector about a browser fork
or a renamed build without waiting for a release.

An empty result means the target is not producing audio right now. Do not fall
back to the bare target PID — that is the case that silently captures nothing.

## Reclaiming leaked capture devices

A process killed mid-capture cannot unwind the private aggregate device its
system tap runs on. Sweep those once at app start, before the first capture:

```dart
await FlutterSystemAudio().cleanupOrphanedCaptureDevices();
```

Only devices this plugin created are touched, and never one a live session in
this process still owns. Platforms with nothing to reclaim return 0.

## Deriving the delay between two captures

Two captures started back to back do not begin at the same instant: the
microphone engine and the system tap each take their own time to produce their
first buffer. Mic-bleed dedup and any cross-source alignment need that skew,
and nothing native reports it — it is derived from the frames themselves.

Both sources timestamp frames from the same monotonic host clock, and expose
which clock that is as `AudioFrame.clockId`. So the delta between the first
frame of each capture *is* the start skew:

```dart
Future<Duration> firstFrameTimestamp(AudioSourceSession session) async =>
    (await session.frames.first).timestamp;

final micStart = await firstFrameTimestamp(micSession);
final systemStart = await firstFrameTimestamp(systemSession);

// Positive: the microphone started later than the system capture.
final micDelay = micStart - systemStart;
final micDelaySeconds = micDelay.inMicroseconds / Duration.microsecondsPerSecond;
```

Two rules make this sound:

- **Compare only frames whose `clockId` matches.** Sources on different clocks
  have unrelated timelines, and subtracting them produces a plausible-looking
  number that means nothing. Both Darwin capture kinds report
  `darwin.host-time`.
- **Take the delta once, from the first frame of each source, and persist it
  with the recording.** It is a property of that recording, not a live signal.
  A capture chain rebuilt mid-recording (an output-device switch, a helper
  process appearing) reports itself as
  `AudioDiscontinuityReason.sourceRestart` on the next frame's
  `AudioFrame.discontinuity`; the timeline continues across it, so the original
  delta stays valid.

`FlutterAudioCaptureHealth.firstAudioAtMillis` answers a different question —
when a source first produced *non-zero* audio, relative to its own session — and
is a diagnostic, not an alignment signal: a silent room delays it without
delaying the frame timeline.
