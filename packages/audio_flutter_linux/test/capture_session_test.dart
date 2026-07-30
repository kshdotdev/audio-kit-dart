import 'dart:async';

import 'package:audio_flutter_linux/audio_flutter_linux.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const PlatformPcmFormat _format = PlatformPcmFormat(
  sampleRate: 16000,
  channelCount: 1,
);

/// 10 ms at 16 kHz mono: 160 samples, 320 bytes.
const Duration _frameDuration = Duration(milliseconds: 10);
const int _samplesPerFrame = 160;

PlatformCaptureRequest _request({
  PlatformCaptureKind kind = PlatformCaptureKind.systemAudio,
  String? inputDeviceId,
  Duration maxBuffered = const Duration(milliseconds: 100),
  PlatformCaptureOverflowPolicy policy =
      PlatformCaptureOverflowPolicy.dropOldest,
  String? rawRecordingPath,
}) => PlatformCaptureRequest(
  kind: kind,
  outputFormat: _format,
  frameDuration: _frameDuration,
  maxBufferedDuration: maxBuffered,
  overflowPolicy: policy,
  inputDeviceId: inputDeviceId,
  rawRecordingPath: rawRecordingPath,
);

FakeProcessRunner _runner({
  Set<String>? unstartable,
  String sink = 'speakers',
}) => FakeProcessRunner(
  installed: <String>{'parecord', 'pw-record', 'pactl', 'paplay'},
  unstartable: unstartable,
  commandResults: <String, LinuxProcessResult>{
    'pactl get-default-sink': LinuxProcessResult(
      exitCode: 0,
      stdout: '$sink\n',
      stderr: '',
    ),
    'pactl get-default-source': const LinuxProcessResult(
      exitCode: 0,
      stdout: 'alsa_input.pci-0000_00_1f.3.analog-stereo\n',
      stderr: '',
    ),
    'pactl list sources short': const LinuxProcessResult(
      exitCode: 0,
      stdout: kPactlSourcesShort,
      stderr: '',
    ),
  },
);

void main() {
  group('spawning', () {
    test('targets the default sink monitor for system audio', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );

      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      await platform.startCapture(info.sessionId);

      expect(info.sourceId, 'speakers.monitor');
      expect(
        runner.startedCommands.single,
        contains('--device=speakers.monitor'),
      );
      await platform.disposeCapture(info.sessionId);
    });

    test(
      'lets the tool pick the default input for microphone capture',
      () async {
        final FakeProcessRunner runner = _runner();
        final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
          runner: runner,
        );

        final PlatformCaptureSessionInfo info = await platform.prepareCapture(
          _request(kind: PlatformCaptureKind.microphone),
        );
        await platform.startCapture(info.sessionId);

        expect(
          runner.startedCommands.single.where(
            (String a) => a.startsWith('--device='),
          ),
          isEmpty,
        );
        await platform.disposeCapture(info.sessionId);
      },
    );

    test('inputDeviceId names the PulseAudio source for either kind', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );

      final PlatformCaptureSessionInfo mic = await platform.prepareCapture(
        _request(
          kind: PlatformCaptureKind.microphone,
          inputDeviceId: 'bluez_input.AC_12_2F.headset',
        ),
      );
      final PlatformCaptureSessionInfo system = await platform.prepareCapture(
        _request(
          inputDeviceId: 'alsa_output.usb-Focusrite.analog-stereo.monitor',
        ),
      );
      await platform.startCapture(mic.sessionId);
      await platform.startCapture(system.sessionId);

      expect(
        runner.startedCommands.first,
        contains('--device=bluez_input.AC_12_2F.headset'),
      );
      expect(
        runner.startedCommands.last,
        contains('--device=alsa_output.usb-Focusrite.analog-stereo.monitor'),
      );
      await platform.disposeCapture(mic.sessionId);
      await platform.disposeCapture(system.sessionId);
    });

    test('falls back to pw-record when parecord cannot start', () async {
      final FakeProcessRunner runner = _runner(
        unstartable: <String>{'parecord'},
      );
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );

      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      await platform.startCapture(info.sessionId);

      expect(runner.startedCommands.single.first, 'pw-record');
      expect(
        runner.startedCommands.single,
        contains('--target=speakers.monitor'),
      );
      await platform.disposeCapture(info.sessionId);
    });

    test('fails loudly when no capture tool starts', () async {
      final FakeProcessRunner runner = _runner(
        unstartable: <String>{'parecord', 'pw-record'},
      );
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      final List<PlatformAudioSessionEvent> events =
          <PlatformAudioSessionEvent>[];
      final StreamSubscription<PlatformAudioSessionEvent> sub = platform
          .captureEvents(info.sessionId)
          .listen(events.add);

      await platform.startCapture(info.sessionId);
      await pumpEventQueue();

      expect(events.last.phase, PlatformAudioSessionPhase.failed);
      expect(events.last.code, 'CaptureToolUnavailable');
      await sub.cancel();
      await platform.disposeCapture(info.sessionId);
    });

    test(
      'rejects a format PulseAudio cannot express before spawning',
      () async {
        final FakeProcessRunner runner = _runner();
        final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
          runner: runner,
        );

        await expectLater(
          platform.prepareCapture(
            PlatformCaptureRequest(
              kind: PlatformCaptureKind.microphone,
              outputFormat: const PlatformPcmFormat(
                sampleRate: 400000,
                channelCount: 1,
              ),
              frameDuration: _frameDuration,
            ),
          ),
          throwsA(isA<LinuxAudioFormatException>()),
        );
        expect(runner.startedCommands, isEmpty);
      },
    );
  });

  group('frame delivery', () {
    test('assembles whole frames and carries a per-channel timeline', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      await platform.startCapture(info.sessionId);

      runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame * 2));
      await pumpEventQueue();

      final PlatformAudioFrameBatch batch = await platform.readCaptureFrames(
        info.sessionId,
        maxFrames: 4,
        timeout: const Duration(milliseconds: 50),
      );

      expect(batch.frames, hasLength(2));
      expect(batch.frames.first.samples, hasLength(_samplesPerFrame));
      expect(batch.frames.first.sampleOffset, 0);
      expect(batch.frames.last.sampleOffset, _samplesPerFrame);
      expect(batch.frames.last.timestamp, const Duration(milliseconds: 10));
      expect(batch.endOfStream, isFalse);
      await platform.disposeCapture(info.sessionId);
    });

    test('carries a partial frame across chunk boundaries', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      await platform.startCapture(info.sessionId);

      // Three chunks that only add up to two whole frames.
      runner.lastHandle.stdoutController
        ..add(pcm16Ramp(100))
        ..add(pcm16Ramp(100, start: 100))
        ..add(pcm16Ramp(140, start: 200));
      await pumpEventQueue();

      final PlatformAudioFrameBatch batch = await platform.readCaptureFrames(
        info.sessionId,
        maxFrames: 8,
        timeout: const Duration(milliseconds: 50),
      );

      expect(batch.frames, hasLength(2));
      await platform.disposeCapture(info.sessionId);
    });

    test('read returns empty after the timeout when nothing arrives', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
        stallTimeout: const Duration(seconds: 30),
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      await platform.startCapture(info.sessionId);

      final PlatformAudioFrameBatch batch = await platform.readCaptureFrames(
        info.sessionId,
        timeout: const Duration(milliseconds: 20),
      );

      expect(batch.frames, isEmpty);
      expect(batch.endOfStream, isFalse);
      await platform.disposeCapture(info.sessionId);
    });

    test('a pending read wakes as soon as a frame lands', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      await platform.startCapture(info.sessionId);

      final Future<PlatformAudioFrameBatch> pending = platform
          .readCaptureFrames(
            info.sessionId,
            timeout: const Duration(seconds: 5),
          );
      await pumpEventQueue();
      runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame));

      expect((await pending).frames, hasLength(1));
      await platform.disposeCapture(info.sessionId);
    });

    test('overflow policy governs the bounded buffer', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      // 30 ms of buffer at a 10 ms frame is a three-frame ring.
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(maxBuffered: const Duration(milliseconds: 30)),
      );
      await platform.startCapture(info.sessionId);

      runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame * 5));
      await pumpEventQueue();

      final PlatformAudioFrameBatch batch = await platform.readCaptureFrames(
        info.sessionId,
        maxFrames: 8,
        timeout: const Duration(milliseconds: 50),
      );

      expect(batch.frames, hasLength(3));
      // The two oldest frames were displaced, and the survivor says so.
      expect(batch.frames.first.sequence, 2);
      expect(batch.frames.first.droppedFramesBefore, 2);
      await platform.disposeCapture(info.sessionId);
    });

    test('failCapture policy terminates the session on overflow', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(
          maxBuffered: const Duration(milliseconds: 20),
          policy: PlatformCaptureOverflowPolicy.failCapture,
        ),
      );
      final List<PlatformAudioSessionEvent> events =
          <PlatformAudioSessionEvent>[];
      final StreamSubscription<PlatformAudioSessionEvent> sub = platform
          .captureEvents(info.sessionId)
          .listen(events.add);
      await platform.startCapture(info.sessionId);

      runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame * 4));
      await pumpEventQueue();

      final PlatformAudioSessionEvent failure = events.lastWhere(
        (PlatformAudioSessionEvent e) =>
            e.phase == PlatformAudioSessionPhase.failed,
      );
      expect(failure.code, 'CaptureMailboxOverflow');
      await sub.cancel();
      await platform.disposeCapture(info.sessionId);
    });
  });

  group('health', () {
    test('reports running once audio actually arrives', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      final List<PlatformAudioSessionEvent> events =
          <PlatformAudioSessionEvent>[];
      final StreamSubscription<PlatformAudioSessionEvent> sub = platform
          .captureEvents(info.sessionId)
          .listen(events.add);

      await platform.startCapture(info.sessionId);
      await pumpEventQueue();
      expect(
        events.map((PlatformAudioSessionEvent e) => e.phase),
        <PlatformAudioSessionPhase>[PlatformAudioSessionPhase.starting],
      );

      runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame));
      await pumpEventQueue();

      expect(events.last.phase, PlatformAudioSessionPhase.running);
      expect(events.last.receivingAudio, isTrue);
      await sub.cancel();
      await platform.disposeCapture(info.sessionId);
    });

    test('a silent source fails as SystemCaptureDead', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
        stallTimeout: const Duration(milliseconds: 30),
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      final List<PlatformAudioSessionEvent> events =
          <PlatformAudioSessionEvent>[];
      final StreamSubscription<PlatformAudioSessionEvent> sub = platform
          .captureEvents(info.sessionId)
          .listen(events.add);

      await platform.startCapture(info.sessionId);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(events.last.phase, PlatformAudioSessionPhase.failed);
      expect(events.last.code, 'SystemCaptureDead');
      expect(events.last.receivingAudio, isFalse);
      await sub.cancel();
      await platform.disposeCapture(info.sessionId);
    });

    test('the watchdog stands down once audio flows', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
        stallTimeout: const Duration(milliseconds: 30),
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      final List<PlatformAudioSessionEvent> events =
          <PlatformAudioSessionEvent>[];
      final StreamSubscription<PlatformAudioSessionEvent> sub = platform
          .captureEvents(info.sessionId)
          .listen(events.add);

      await platform.startCapture(info.sessionId);
      runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        events.where(
          (PlatformAudioSessionEvent e) =>
              e.phase == PlatformAudioSessionPhase.failed,
        ),
        isEmpty,
      );
      await sub.cancel();
      await platform.disposeCapture(info.sessionId);
    });

    test('an unexpected exit reports the stderr excerpt', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      final List<PlatformAudioSessionEvent> events =
          <PlatformAudioSessionEvent>[];
      final StreamSubscription<PlatformAudioSessionEvent> sub = platform
          .captureEvents(info.sessionId)
          .listen(events.add);
      await platform.startCapture(info.sessionId);

      runner.lastHandle.stderrController.add(
        'Connection failure: Connection refused'.codeUnits,
      );
      await pumpEventQueue();
      runner.lastHandle.complete(1);
      await pumpEventQueue();

      expect(events.last.phase, PlatformAudioSessionPhase.failed);
      expect(events.last.code, 'CaptureProcessExited');
      expect(events.last.message, contains('Connection refused'));
      await sub.cancel();
      await platform.disposeCapture(info.sessionId);
    });

    test('stderr is drained even when it is never inspected', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      await platform.startCapture(info.sessionId);

      expect(runner.lastHandle.stderrController.hasListener, isTrue);
      await platform.disposeCapture(info.sessionId);
    });

    test('a graceful stop is not reported as a failure', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      final List<PlatformAudioSessionEvent> events =
          <PlatformAudioSessionEvent>[];
      final StreamSubscription<PlatformAudioSessionEvent> sub = platform
          .captureEvents(info.sessionId)
          .listen(events.add);
      await platform.startCapture(info.sessionId);
      runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame));
      await pumpEventQueue();

      await platform.stopCapture(info.sessionId);
      await pumpEventQueue();

      expect(runner.lastHandle.killed, isTrue);
      expect(
        events.map((PlatformAudioSessionEvent e) => e.phase),
        containsAllInOrder(<PlatformAudioSessionPhase>[
          PlatformAudioSessionPhase.stopping,
          PlatformAudioSessionPhase.stopped,
        ]),
      );
      expect(
        events.where(
          (PlatformAudioSessionEvent e) =>
              e.phase == PlatformAudioSessionPhase.failed,
        ),
        isEmpty,
      );
      await sub.cancel();
      await platform.disposeCapture(info.sessionId);
    });

    test(
      'stopping drains what was already buffered and ends the stream',
      () async {
        final FakeProcessRunner runner = _runner();
        final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
          runner: runner,
        );
        final PlatformCaptureSessionInfo info = await platform.prepareCapture(
          _request(),
        );
        await platform.startCapture(info.sessionId);
        runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame));
        await pumpEventQueue();
        await platform.stopCapture(info.sessionId);

        final PlatformAudioFrameBatch batch = await platform.readCaptureFrames(
          info.sessionId,
          timeout: const Duration(milliseconds: 10),
        );
        expect(batch.frames, hasLength(1));
        expect(batch.endOfStream, isTrue);
        await platform.disposeCapture(info.sessionId);
      },
    );

    test('abort discards buffered audio', () async {
      final FakeProcessRunner runner = _runner();
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      await platform.startCapture(info.sessionId);
      runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame));
      await pumpEventQueue();

      await platform.abortCapture(info.sessionId);
      final PlatformAudioFrameBatch batch = await platform.readCaptureFrames(
        info.sessionId,
        timeout: const Duration(milliseconds: 10),
      );

      expect(batch.frames, isEmpty);
      expect(batch.endOfStream, isTrue);
      await platform.disposeCapture(info.sessionId);
    });
  });

  group('raw recording', () {
    test('mirrors captured PCM and finalizes on stop', () async {
      final FakeProcessRunner runner = _runner();
      final List<FakeRecordingSink> sinks = <FakeRecordingSink>[];
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
        recordingSinkFactory: (String path, PlatformPcmFormat format) {
          final FakeRecordingSink sink = FakeRecordingSink(path, format);
          sinks.add(sink);
          return sink;
        },
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(rawRecordingPath: '/tmp/capture.wav'),
      );
      await platform.startCapture(info.sessionId);

      runner.lastHandle.stdoutController.add(pcm16Ramp(_samplesPerFrame));
      await pumpEventQueue();
      await platform.stopCapture(info.sessionId);

      expect(sinks.single.path, '/tmp/capture.wav');
      expect(sinks.single.opened, isTrue);
      expect(sinks.single.written.length, _samplesPerFrame * 2);
      expect(sinks.single.closed, isTrue);
      expect(sinks.single.aborted, isFalse);
      await platform.disposeCapture(info.sessionId);
    });

    test('no sink is opened when no recording was requested', () async {
      final FakeProcessRunner runner = _runner();
      var built = 0;
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
        recordingSinkFactory: (String path, PlatformPcmFormat format) {
          built++;
          return FakeRecordingSink(path, format);
        },
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        _request(),
      );
      await platform.startCapture(info.sessionId);

      expect(built, 0);
      await platform.disposeCapture(info.sessionId);
    });
  });
}
