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
      'pactl --format=json list sink-inputs': LinuxProcessResult(
        exitCode: 0,
        stdout: kPactlSinkInputsJson,
        stderr: '',
      ),
    };

void main() {
  group('support probes', () {
    test('needs a capture tool, pactl, and an exposed monitor', () async {
      Future<bool> supported(
        Set<String> installed, {
        String sources = kPactlSourcesShort,
      }) => LinuxAudioFlutterPlatform(
        runner: FakeProcessRunner(
          installed: installed,
          commandResults: <String, LinuxProcessResult>{
            'pactl list sources short': LinuxProcessResult(
              exitCode: 0,
              stdout: sources,
              stderr: '',
            ),
          },
        ),
      ).isSystemAudioCaptureSupported();

      expect(await supported(<String>{'parecord', 'pactl'}), isTrue);
      expect(await supported(<String>{'pw-record', 'pactl'}), isTrue);
      expect(await supported(<String>{'parecord'}), isFalse);
      expect(await supported(<String>{'pactl'}), isFalse);
      expect(await supported(<String>{}), isFalse);
      expect(
        await supported(
          <String>{'parecord', 'pactl'},
          sources: '1\talsa_input.usb-mic\tPipeWire\ts16le 1ch 48000Hz\tIDLE\n',
        ),
        isFalse,
      );
    });

    test('permission mirrors capability, since Linux has no grant', () async {
      final LinuxAudioFlutterPlatform granted = LinuxAudioFlutterPlatform(
        runner: FakeProcessRunner(
          installed: <String>{'parecord', 'pactl'},
          commandResults: const <String, LinuxProcessResult>{
            'pactl list sources short': LinuxProcessResult(
              exitCode: 0,
              stdout: kPactlSourcesShort,
              stderr: '',
            ),
          },
        ),
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

    test('lists only addressable local audio processes', () async {
      final List<PlatformAudioProcess> processes = await build()
          .listAudioProcesses();

      expect(processes.map((PlatformAudioProcess p) => p.processId), <int>[
        4242,
        4343,
      ]);
      expect(processes.first.bundleId, 'chrome');
      expect(processes.first.isProducingAudio, isTrue);
      expect(processes.last.isProducingAudio, isFalse);
    });

    test(
      'normalizes PipeWire monitors and addressable process streams',
      () async {
        final LinuxAudioFlutterPlatform platform = build();
        final PlatformCaptureBackendInfo backend = await platform
            .captureBackendInfo();
        final List<PlatformCaptureSourceInfo> sources = await platform
            .listCaptureSources();

        expect(
          backend.sourceKinds,
          containsAll(<PlatformCaptureSourceKind>[
            PlatformCaptureSourceKind.microphone,
            PlatformCaptureSourceKind.application,
            PlatformCaptureSourceKind.browser,
            PlatformCaptureSourceKind.pipeWireMonitor,
          ]),
        );
        expect(
          backend.capabilities,
          containsAll(<PlatformCaptureCapability>[
            PlatformCaptureCapability.processFiltering,
            PlatformCaptureCapability.applicationFiltering,
          ]),
        );
        expect(
          sources
              .where(
                (PlatformCaptureSourceInfo source) =>
                    source.kind == PlatformCaptureSourceKind.pipeWireMonitor,
              )
              .length,
          2,
        );
        expect(
          sources
              .where(
                (PlatformCaptureSourceInfo source) =>
                    source.kind == PlatformCaptureSourceKind.pipeWireMonitor,
              )
              .every(
                (PlatformCaptureSourceInfo source) =>
                    source.timingQuality ==
                    PlatformCaptureTimingQuality.synthesized,
              ),
          isTrue,
        );
        final PlatformCaptureSourceInfo application = sources.singleWhere(
          (PlatformCaptureSourceInfo source) =>
              source.kind == PlatformCaptureSourceKind.application,
        );
        expect(
          application.availability,
          PlatformCaptureSourceAvailability.available,
        );
        expect(application.processIds, <int>[4343]);
        expect(application.inputDeviceId, 'pulse-monitor-stream:43');
        final PlatformCaptureSourceInfo browser = sources.singleWhere(
          (PlatformCaptureSourceInfo source) =>
              source.kind == PlatformCaptureSourceKind.browser,
        );
        expect(browser.processIds, <int>[4242]);
        expect(browser.inputDeviceId, 'pulse-monitor-stream:42');
      },
    );

    test(
      'rejects bare process IDs instead of widening to a monitor mix',
      () async {
        await expectLater(
          build().prepareCapture(
            const PlatformCaptureRequest(
              kind: PlatformCaptureKind.systemAudio,
              outputFormat: PlatformPcmFormat(
                sampleRate: 16000,
                channelCount: 1,
              ),
              processIds: <int>[42],
            ),
          ),
          throwsA(
            isA<UnsupportedError>().having(
              (UnsupportedError error) => error.message,
              'message',
              contains('UnsupportedProcessCapture'),
            ),
          ),
        );
      },
    );

    test('starts an exact addressable stream with no broad fallback', () async {
      final FakeProcessRunner runner = FakeProcessRunner(
        installed: <String>{'parecord', 'pw-record', 'pactl'},
        commandResults: _pactlResults,
      );
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: runner,
      );
      final PlatformCaptureSessionInfo info = await platform.prepareCapture(
        const PlatformCaptureRequest(
          kind: PlatformCaptureKind.systemAudio,
          outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
          processIds: <int>[4242],
          inputDeviceId: 'pulse-monitor-stream:42',
        ),
      );

      await platform.startCapture(info.sessionId);

      expect(runner.startedCommands.single, contains('--monitor-stream=42'));
      expect(runner.startedCommands.single.first, 'parecord');
      expect(
        runner.startedCommands.single,
        isNot(contains(startsWith('--device='))),
      );
      await platform.abortCapture(info.sessionId);
      await platform.disposeCapture(info.sessionId);
    });

    test(
      'revalidates an addressable stream immediately before start',
      () async {
        final FakeProcessRunner runner = FakeProcessRunner(
          installed: <String>{'parecord', 'pactl'},
          commandResults: Map<String, LinuxProcessResult>.of(_pactlResults),
        );
        final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
          runner: runner,
        );
        final PlatformCaptureSessionInfo info = await platform.prepareCapture(
          const PlatformCaptureRequest(
            kind: PlatformCaptureKind.systemAudio,
            outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
            processIds: <int>[4242],
            inputDeviceId: 'pulse-monitor-stream:42',
          ),
        );
        runner.commandResults['pactl --format=json list sink-inputs'] =
            const LinuxProcessResult(exitCode: 0, stdout: '[]', stderr: '');

        await expectLater(
          platform.startCapture(info.sessionId),
          throwsA(
            isA<StateError>().having(
              (StateError error) => error.message,
              'message',
              contains('ProcessCaptureSourceExpired'),
            ),
          ),
        );
        expect(runner.startedCommands, isEmpty);
        await platform.disposeCapture(info.sessionId);
      },
    );

    test('never maps missing system audio to the default microphone', () async {
      final LinuxAudioFlutterPlatform platform = LinuxAudioFlutterPlatform(
        runner: FakeProcessRunner(
          installed: <String>{'parecord', 'pactl'},
          commandResults: const <String, LinuxProcessResult>{
            'pactl get-default-sink': LinuxProcessResult(
              exitCode: 1,
              stdout: '',
              stderr: 'no default sink',
            ),
          },
        ),
      );

      await expectLater(
        platform.prepareCapture(
          const PlatformCaptureRequest(
            kind: PlatformCaptureKind.systemAudio,
            outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
          ),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (UnsupportedError error) => error.message,
            'message',
            contains('SystemAudioSourceUnavailable'),
          ),
        ),
      );
    });

    test('rejects a process set wider than the selected stream', () async {
      await expectLater(
        build().prepareCapture(
          const PlatformCaptureRequest(
            kind: PlatformCaptureKind.systemAudio,
            outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
            processIds: <int>[4242, 4343],
            inputDeviceId: 'pulse-monitor-stream:42',
          ),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (UnsupportedError error) => error.message,
            'message',
            contains('UnsupportedProcessSet'),
          ),
        ),
      );
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
