import 'dart:typed_data';

import 'package:audio_flutter_linux/audio_flutter_linux.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const Map<String, LinuxProcessResult> _pactlResults =
    <String, LinuxProcessResult>{
      'pactl list sources short': LinuxProcessResult(
        exitCode: 0,
        stdout: kPactlSourcesShort,
        stderr: '',
      ),
      'pactl get-default-source': LinuxProcessResult(
        exitCode: 0,
        stdout: 'bluez_input.AC_12_2F.headset\n',
        stderr: '',
      ),
      'pactl get-default-sink': LinuxProcessResult(
        exitCode: 0,
        stdout: 'alsa_output.pci-0000_00_1f.3.analog-stereo\n',
        stderr: '',
      ),
    };

void main() {
  group('support probes', () {
    test('needs both a capture tool and pactl', () async {
      Future<bool> supported(Set<String> installed) =>
          LinuxAudioFlutterPlatform(
            runner: FakeProcessRunner(installed: installed),
          ).isSystemAudioCaptureSupported();

      expect(await supported(<String>{'parecord', 'pactl'}), isTrue);
      expect(await supported(<String>{'pw-record', 'pactl'}), isTrue);
      expect(await supported(<String>{'parecord'}), isFalse);
      expect(await supported(<String>{'pactl'}), isFalse);
      expect(await supported(<String>{}), isFalse);
    });

    test('permission mirrors capability, since Linux has no grant', () async {
      final LinuxAudioFlutterPlatform granted = LinuxAudioFlutterPlatform(
        runner: FakeProcessRunner(installed: <String>{'parecord', 'pactl'}),
      );
      final LinuxAudioFlutterPlatform ungranted = LinuxAudioFlutterPlatform(
        runner: FakeProcessRunner(),
      );

      expect(await granted.requestSystemAudioCapturePermission(), isTrue);
      expect(await ungranted.requestSystemAudioCapturePermission(), isFalse);
    });
  });

  group('enumeration', () {
    LinuxAudioFlutterPlatform build() => LinuxAudioFlutterPlatform(
      runner: FakeProcessRunner(
        installed: <String>{'parecord', 'pactl'},
        commandResults: _pactlResults,
      ),
    );

    test('input devices exclude monitors and flag the default', () async {
      final List<PlatformAudioInputDevice> devices = await build()
          .listAudioInputDevices();

      expect(devices.map((PlatformAudioInputDevice d) => d.id), <String>[
        'alsa_input.pci-0000_00_1f.3.analog-stereo',
        'bluez_input.AC_12_2F.headset',
      ]);
      expect(
        devices.singleWhere((PlatformAudioInputDevice d) => d.isDefault).id,
        'bluez_input.AC_12_2F.headset',
      );
    });

    test('system sources are the monitors, defaulted from the sink', () async {
      final List<PlatformAudioInputDevice> sources = await build()
          .listSystemAudioSources();

      expect(sources.map((PlatformAudioInputDevice d) => d.id), <String>[
        'alsa_output.pci-0000_00_1f.3.analog-stereo.monitor',
        'alsa_output.usb-Focusrite.analog-stereo.monitor',
      ]);
      expect(sources.first.isDefault, isTrue);
      expect(sources.last.isDefault, isFalse);
    });

    test('enumeration degrades to empty when pactl is unavailable', () async {
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: FakeProcessRunner(installed: <String>{'parecord'}),
      );

      expect(await platform.listAudioInputDevices(), isEmpty);
      expect(await platform.listSystemAudioSources(), isEmpty);
    });

    test('there is no per-process capture on Linux', () async {
      expect(await build().listAudioProcesses(), isEmpty);
    });
  });

  group('playback', () {
    PlatformPlaybackRequest request() => const PlatformPlaybackRequest(
      inputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
    );

    PlatformAudioFrame frame(List<double> samples) => PlatformAudioFrame(
      sessionId: 1,
      sequence: 0,
      sampleOffset: 0,
      timestamp: Duration.zero,
      samples: Float32List.fromList(samples),
    );

    test(
      'writes encoded PCM to the tool stdin and closes it on finish',
      () async {
        final FakeProcessRunner runner = FakeProcessRunner(
          installed: <String>{'paplay'},
        );
        final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
          runner: runner,
        );
        final PlatformPlaybackSessionInfo info = await platform.preparePlayback(
          request(),
        );
        await platform.startPlayback(info.sessionId);

        await platform.writePlaybackFrames(info.sessionId, <PlatformAudioFrame>[
          frame(<double>[0, 1, -1]),
        ]);

        expect(runner.startedCommands.single, <String>[
          'paplay',
          '--raw',
          '--rate=16000',
          '--channels=1',
          '--format=s16le',
        ]);
        final Uint8List written = runner.lastHandle.stdinWrites.toBytes();
        final ByteData data = ByteData.sublistView(written);
        expect(written, hasLength(6));
        expect(data.getInt16(0, Endian.little), 0);
        expect(data.getInt16(2, Endian.little), 32767);
        expect(data.getInt16(4, Endian.little), -32768);

        final FakeProcessHandle handle = runner.lastHandle;
        final Future<void> finishing = platform.finishPlayback(info.sessionId);
        await pumpEventQueue();
        handle.complete(0);
        await finishing;

        expect(handle.stdinClosed, isTrue);
        await platform.disposePlayback(info.sessionId);
      },
    );

    test('falls back to pw-play when paplay cannot start', () async {
      final FakeProcessRunner runner = FakeProcessRunner(
        installed: <String>{'pw-play'},
        unstartable: <String>{'paplay'},
      );
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformPlaybackSessionInfo info = await platform.preparePlayback(
        request(),
      );

      await platform.startPlayback(info.sessionId);

      expect(runner.startedCommands.single.first, 'pw-play');
      await platform.disposePlayback(info.sessionId);
    });

    test('abort kills the tool without draining', () async {
      final FakeProcessRunner runner = FakeProcessRunner(
        installed: <String>{'paplay'},
      );
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformPlaybackSessionInfo info = await platform.preparePlayback(
        request(),
      );
      await platform.startPlayback(info.sessionId);

      await platform.abortPlayback(info.sessionId);

      expect(runner.lastHandle.killed, isTrue);
      expect(runner.lastHandle.stdinClosed, isFalse);
      await platform.disposePlayback(info.sessionId);
    });

    test('rejects a format PulseAudio cannot express', () async {
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: FakeProcessRunner(installed: <String>{'paplay'}),
      );

      await expectLater(
        platform.preparePlayback(
          const PlatformPlaybackRequest(
            inputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 64),
          ),
        ),
        throwsA(isA<LinuxAudioFormatException>()),
      );
    });
  });

  test('unknown session ids are rejected, not silently ignored', () async {
    final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
      runner: FakeProcessRunner(),
    );

    expect(() => platform.startCapture(404), throwsStateError);
    expect(() => platform.startPlayback(404), throwsStateError);
    expect(platform.captureEvents(404), emitsDone);
    // Disposing an unknown session is a no-op so cleanup paths stay safe.
    await platform.disposeCapture(404);
  });
}
