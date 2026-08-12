import 'dart:async';

import 'package:audio_flutter_darwin/audio_flutter_darwin.dart';
import 'package:audio_flutter_darwin/src/messages.g.dart' as pigeon;
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normalizes CATap microphone, process, and system sources', () async {
    final _FakeDarwinHost host = _FakeDarwinHost(
      systemCaptureSupported: true,
      microphonePermission:
          pigeon.MicrophonePermissionStatusMessage.notDetermined,
      inputs: <pigeon.AudioInputDeviceMessage>[
        pigeon.AudioInputDeviceMessage(
          id: 'built-in-mic',
          label: 'MacBook Microphone',
          isDefault: true,
        ),
      ],
      processes: <pigeon.AudioProcessMessage>[
        pigeon.AudioProcessMessage(
          processId: 42,
          bundleId: 'com.example.meeting',
          isProducingAudio: true,
        ),
      ],
    );
    final DarwinAudioFlutterPlatform platform = DarwinAudioFlutterPlatform(
      hostApi: host,
      events: const Stream<pigeon.AudioSessionEventMessage>.empty(),
    );

    final PlatformCaptureBackendInfo backend = await platform
        .captureBackendInfo();
    final List<PlatformCaptureSourceInfo> sources = await platform
        .listCaptureSources();
    final PlatformCaptureSessionInfo session = await platform.prepareCapture(
      const PlatformCaptureRequest(
        kind: PlatformCaptureKind.systemAudio,
        outputFormat: PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
        processIds: <int>[42],
        bundleIds: <String>['com.example.meeting'],
      ),
    );

    expect(
      backend.capabilities,
      containsAll(<PlatformCaptureCapability>[
        PlatformCaptureCapability.processFiltering,
        PlatformCaptureCapability.nativeMonotonicClock,
      ]),
    );
    final PlatformCaptureSourceInfo microphone = sources.singleWhere(
      (PlatformCaptureSourceInfo source) =>
          source.kind == PlatformCaptureSourceKind.microphone,
    );
    expect(
      microphone.availability,
      PlatformCaptureSourceAvailability.permissionRequired,
    );
    expect(microphone.isDefault, isTrue);
    final PlatformCaptureSourceInfo process = sources.singleWhere(
      (PlatformCaptureSourceInfo source) =>
          source.sourceId == 'darwin.process.42',
    );
    expect(process.processIds, <int>[42]);
    expect(process.applicationId, 'com.example.meeting');
    // Both selections reach the native request: the process objects a tap
    // resolves today, and the identities it keeps following afterwards.
    expect(host.lastCaptureRequest?.processIds, <int>[42]);
    expect(host.lastCaptureRequest?.bundleIds, <String>['com.example.meeting']);
    expect(process.timingQuality, PlatformCaptureTimingQuality.nativeMapped);
    expect(session.timingQuality, PlatformCaptureTimingQuality.nativeMapped);
    expect(
      sources
          .singleWhere(
            (PlatformCaptureSourceInfo source) =>
                source.kind == PlatformCaptureSourceKind.systemMix,
          )
          .availability,
      PlatformCaptureSourceAvailability.available,
    );
    expect(
      sources
          .singleWhere(
            (PlatformCaptureSourceInfo source) =>
                source.kind == PlatformCaptureSourceKind.browser,
          )
          .availabilityCode,
      'darwin_browser_grouping_requires_host_selection',
    );
  });

  test(
    'guards CATap descriptors when the Darwin target cannot support them',
    () async {
      final _FakeDarwinHost host = _FakeDarwinHost(
        systemCaptureSupported: false,
        microphonePermission: pigeon.MicrophonePermissionStatusMessage.granted,
      );
      final DarwinAudioFlutterPlatform platform = DarwinAudioFlutterPlatform(
        hostApi: host,
        events: const Stream<pigeon.AudioSessionEventMessage>.empty(),
      );

      final List<PlatformCaptureSourceInfo> sources = await platform
          .listCaptureSources();
      final PlatformCaptureSourceInfo system = sources.singleWhere(
        (PlatformCaptureSourceInfo source) =>
            source.kind == PlatformCaptureSourceKind.systemMix,
      );
      final PlatformCaptureSourceInfo application = sources.singleWhere(
        (PlatformCaptureSourceInfo source) =>
            source.kind == PlatformCaptureSourceKind.application,
      );

      expect(
        system.availability,
        PlatformCaptureSourceAvailability.unavailable,
      );
      expect(system.availabilityCode, 'darwin_catap_unavailable');
      expect(
        application.availabilityCode,
        'darwin_process_capture_unavailable',
      );
      expect(host.listProcessesCalls, 0);
    },
  );
}

final class _FakeDarwinHost extends pigeon.DarwinAudioHostApi {
  _FakeDarwinHost({
    required this.systemCaptureSupported,
    required this.microphonePermission,
    this.inputs = const <pigeon.AudioInputDeviceMessage>[],
    this.processes = const <pigeon.AudioProcessMessage>[],
  });

  final bool systemCaptureSupported;
  final pigeon.MicrophonePermissionStatusMessage microphonePermission;
  final List<pigeon.AudioInputDeviceMessage> inputs;
  final List<pigeon.AudioProcessMessage> processes;
  var listProcessesCalls = 0;
  pigeon.CaptureRequestMessage? lastCaptureRequest;

  @override
  Future<pigeon.CaptureSessionInfoMessage> prepareCapture(
    pigeon.CaptureRequestMessage request,
  ) async {
    lastCaptureRequest = request;
    return pigeon.CaptureSessionInfoMessage(
      sessionId: 1,
      sourceId: 'darwin-source',
      trackId: 'them',
      clockId: 'darwin.host-time',
      format: request.outputFormat,
    );
  }

  @override
  Future<bool> isSystemAudioCaptureSupported() async => systemCaptureSupported;

  @override
  Future<pigeon.MicrophonePermissionStatusMessage>
  microphonePermissionStatus() async => microphonePermission;

  @override
  Future<List<pigeon.AudioInputDeviceMessage>> listAudioInputDevices() async =>
      inputs;

  @override
  Future<List<pigeon.AudioProcessMessage>> listAudioProcesses() async {
    listProcessesCalls += 1;
    return processes;
  }
}
