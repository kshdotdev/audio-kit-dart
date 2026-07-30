// Real-server smoke test for audio_flutter_linux.
//
// Opens a genuine PulseAudio/PipeWire capture against a monitor source and
// asserts that frames actually arrive. Everything the unit suite covers is
// mocked behind the process seam; this is the only check that proves the
// `parecord`/`pw-record` argument strings and the stdout framing work against
// a live sound server.
//
// It is a plain Dart entrypoint, not a Flutter test: nothing in
// audio_flutter_linux touches `dart:ui`, so it runs under the bare VM.
//
// Usage, with a null sink already loaded:
//
//   pactl load-module module-null-sink sink_name=ci_sink
//   dart run tool/pulse_capture_smoke.dart --source ci_sink.monitor
//
// Omitting `--source` targets the default sink's monitor. Exits 0 when audio
// was captured, 1 with a diagnostic otherwise.

import 'dart:async';
import 'dart:io';

import 'package:audio_flutter_linux/audio_flutter_linux.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// Sample rate requested from the sound server.
const int _sampleRate = 48000;

/// Interleaved channel count requested from the sound server.
const int _channelCount = 1;

/// Frames the session hands back per pull.
const Duration _frameDuration = Duration(milliseconds: 100);

Future<void> main(List<String> arguments) async {
  final String? source = _stringOption(arguments, '--source');
  final Duration window = Duration(
    milliseconds:
        (double.parse(_stringOption(arguments, '--seconds') ?? '2') * 1000)
            .round(),
  );

  final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform();

  if (!await platform.isSystemAudioCaptureSupported()) {
    _fail(
      'No capture tool found. Install pulseaudio-utils (parecord, pactl) or '
      'pipewire-utils (pw-record).',
    );
  }

  final List<PlatformAudioInputDevice> monitors = await platform
      .listSystemAudioSources();
  stdout.writeln('Monitor sources (${monitors.length}):');
  for (final PlatformAudioInputDevice monitor in monitors) {
    stdout.writeln(
      '  ${monitor.id}${monitor.isDefault ? '  (default)' : ''}  '
      '-- ${monitor.label}',
    );
  }
  if (monitors.isEmpty) {
    _fail('No monitor sources. Load a null sink before running this script.');
  }
  if (source != null &&
      !monitors.any((PlatformAudioInputDevice m) => m.id == source)) {
    _fail('Requested source "$source" is not among the monitor sources above.');
  }

  final PlatformCaptureSessionInfo info = await platform.prepareCapture(
    PlatformCaptureRequest(
      kind: PlatformCaptureKind.systemAudio,
      outputFormat: const PlatformPcmFormat(
        sampleRate: _sampleRate,
        channelCount: _channelCount,
      ),
      frameDuration: _frameDuration,
      overflowPolicy: PlatformCaptureOverflowPolicy.dropOldest,
      inputDeviceId: source,
    ),
  );
  stdout.writeln('Prepared session ${info.sessionId} on ${info.sourceId}.');

  final List<String> phases = <String>[];
  bool receivingAudio = false;
  final StreamSubscription<PlatformAudioSessionEvent> events = platform
      .captureEvents(info.sessionId)
      .listen((PlatformAudioSessionEvent event) {
        phases.add(event.phase.name);
        receivingAudio = receivingAudio || (event.receivingAudio ?? false);
        if (event.code != null) {
          stdout.writeln(
            '  event ${event.phase.name}: '
            '${event.code} ${event.message ?? ''}',
          );
        }
      });

  int frameCount = 0;
  int sampleCount = 0;
  int droppedFrames = 0;
  Object? failure;

  try {
    await platform.startCapture(info.sessionId);
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < window) {
      final PlatformAudioFrameBatch batch = await platform.readCaptureFrames(
        info.sessionId,
        timeout: const Duration(milliseconds: 500),
      );
      for (final PlatformAudioFrame frame in batch.frames) {
        frameCount++;
        sampleCount += frame.samples.length;
        droppedFrames += frame.droppedFramesBefore;
      }
      if (batch.endOfStream) {
        break;
      }
    }
    await platform.stopCapture(info.sessionId);
  } catch (error) {
    failure = error;
    await platform.abortCapture(info.sessionId).catchError((Object _) {});
  } finally {
    await events.cancel();
    await platform.disposeCapture(info.sessionId);
  }

  stdout.writeln('Phases: ${phases.join(' -> ')}');
  stdout.writeln('receivingAudio: $receivingAudio');
  stdout.writeln(
    'Captured $frameCount frame(s), $sampleCount sample(s), '
    '$droppedFrames dropped, over ${window.inMilliseconds} ms.',
  );

  if (failure != null) {
    _fail('Capture failed: $failure');
  }

  // Half the nominal frame count over the window. A live server can be slow to
  // hand over the first packet; delivering nothing at all is the failure this
  // script exists to catch.
  final int minimumFrames =
      (window.inMilliseconds ~/ _frameDuration.inMilliseconds) ~/ 2;
  if (frameCount < minimumFrames) {
    _fail('Expected at least $minimumFrames frame(s), got $frameCount.');
  }
  if (sampleCount < frameCount * _sampleRate * _channelCount ~/ 10) {
    _fail('Frames arrived but carried fewer samples than one frame duration.');
  }
  if (!receivingAudio) {
    _fail('Frames arrived but the session never reported receivingAudio.');
  }

  stdout.writeln('OK: real PulseAudio capture delivered audio.');
}

String? _stringOption(List<String> arguments, String name) {
  final int index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) {
    return null;
  }
  return arguments[index + 1];
}

Never _fail(String message) {
  stderr.writeln('FAIL: $message');
  exit(1);
}
