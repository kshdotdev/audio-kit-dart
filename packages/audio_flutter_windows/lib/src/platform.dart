import 'dart:async';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter/services.dart';

import 'channel.dart';
import 'codec.dart';

/// Registers the Windows implementation selected by audio_flutter's
/// `default_package` declaration.
abstract final class AudioFlutterWindows {
  static void registerWith() {
    AudioFlutterPlatform.instance = WindowsAudioFlutterPlatform();
  }
}

/// WASAPI-backed Windows implementation of the federated platform contract.
///
/// The native plugin owns capture sessions, their bounded frame rings, and the
/// WASAPI threads; this class is the typed channel client in front of it. Audio
/// is pulled with [readCaptureFrames] and never pushed, so the native ring — not
/// a Dart-side queue — is where backpressure is applied.
///
/// ## Targeting
///
/// [PlatformCaptureRequest.inputDeviceId] carries a WASAPI endpoint id for both
/// capture kinds: an `eCapture` endpoint for [PlatformCaptureKind.microphone],
/// an `eRender` endpoint for [PlatformCaptureKind.systemAudio] (loopback taps
/// the render endpoint's mix). Null selects the respective default endpoint.
/// [listSystemAudioSources] enumerates the render endpoints available for the
/// latter, mirroring the Linux implementation's affordance.
///
/// Process IDs use Windows application loopback and are never widened to a
/// render-endpoint mix. Microsoft supports that activation contract from OS
/// build 20348; older Windows 10 hosts remain fully usable for explicit system
/// mix capture but report application sources as unavailable.
final class WindowsAudioFlutterPlatform extends AudioFlutterPlatform {
  WindowsAudioFlutterPlatform({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _method = methodChannel ?? const MethodChannel(kWindowsMethodChannel),
       _events = eventChannel ?? const EventChannel(kWindowsEventChannel);

  final MethodChannel _method;
  final EventChannel _events;

  Stream<PlatformAudioSessionEvent>? _sessionEvents;

  /// One broadcast subscription to the native event channel, demultiplexed per
  /// session by [_eventsFor]. A channel-per-session would make the plugin hold
  /// one sink per capture for no benefit.
  Stream<PlatformAudioSessionEvent> get _allEvents => _sessionEvents ??= _events
      .receiveBroadcastStream()
      .map(
        (Object? event) => decodeSessionEvent(event! as Map<Object?, Object?>),
      )
      .asBroadcastStream();

  Stream<PlatformAudioSessionEvent> _eventsFor(int sessionId) => _allEvents
      .where((PlatformAudioSessionEvent event) => event.sessionId == sessionId);

  @override
  Future<PlatformCaptureSessionInfo> prepareCapture(
    PlatformCaptureRequest request,
  ) async {
    if (request.processIds.isNotEmpty) {
      if (request.kind != PlatformCaptureKind.systemAudio) {
        throw UnsupportedError(
          'UnsupportedProcessCapture: process IDs are valid only for system '
          'audio capture',
        );
      }
      if (request.inputDeviceId != null) {
        throw UnsupportedError(
          'UnsupportedProcessCaptureEndpoint: Windows process loopback spans '
          'render endpoints and cannot also select an endpoint',
        );
      }
      if (!await isProcessAudioCaptureSupported()) {
        throw UnsupportedError(
          'UnsupportedProcessCapture: Windows application loopback requires '
          'OS build 20348 or newer',
        );
      }
    }
    if (request.rawRecordingPath != null) {
      throw UnsupportedError(
        'UnsupportedRawRecording: audio_flutter_windows does not implement '
        'source-side recording; record from the pulled frames instead',
      );
    }
    final Map<Object?, Object?> reply = await _invokeMap(
      kMethodPrepareCapture,
      encodeCaptureRequest(request),
    );
    return decodeCaptureSessionInfo(reply);
  }

  @override
  Stream<PlatformAudioSessionEvent> captureEvents(int sessionId) =>
      _eventsFor(sessionId);

  @override
  Future<void> startCapture(int sessionId) => _method.invokeMethod<void>(
    kMethodStartCapture,
    <String, Object?>{'sessionId': sessionId},
  );

  @override
  Future<PlatformAudioFrameBatch> readCaptureFrames(
    int sessionId, {
    int maxFrames = 8,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final Map<Object?, Object?> reply =
        await _invokeMap(kMethodReadCaptureFrames, <String, Object?>{
          'sessionId': sessionId,
          'maxFrames': maxFrames,
          'timeoutMillis': timeout.inMilliseconds,
        });
    return decodeFrameBatch(reply);
  }

  @override
  Future<void> stopCapture(int sessionId) => _method.invokeMethod<void>(
    kMethodStopCapture,
    <String, Object?>{'sessionId': sessionId},
  );

  @override
  Future<void> abortCapture(int sessionId) => _method.invokeMethod<void>(
    kMethodAbortCapture,
    <String, Object?>{'sessionId': sessionId},
  );

  @override
  Future<void> disposeCapture(int sessionId) => _method.invokeMethod<void>(
    kMethodDisposeCapture,
    <String, Object?>{'sessionId': sessionId},
  );

  /// True whenever the process can open a shared-mode loopback client, which on
  /// Windows means "always" — there is no OS version gate comparable to macOS
  /// 14.4 and no capability that can be revoked.
  @override
  Future<bool> isSystemAudioCaptureSupported() async =>
      await _method.invokeMethod<bool>(kMethodIsSystemAudioCaptureSupported) ??
      false;

  /// Always granted: Windows has no permission gate for shared-mode loopback on
  /// a render endpoint. Reported through the same contract so callers do not
  /// need a platform branch.
  @override
  Future<bool> requestSystemAudioCapturePermission() async =>
      await _method.invokeMethod<bool>(
        kMethodRequestSystemAudioCapturePermission,
      ) ??
      false;

  /// Whether the host implements Microsoft's application-loopback activation.
  Future<bool> isProcessAudioCaptureSupported() async =>
      await _method.invokeMethod<bool>(kMethodIsProcessAudioCaptureSupported) ??
      false;

  @override
  Future<PlatformCaptureBackendInfo> captureBackendInfo() async {
    final bool systemCaptureSupported = await isSystemAudioCaptureSupported();
    final bool processCaptureSupported = await isProcessAudioCaptureSupported();
    return PlatformCaptureBackendInfo(
      backendId: 'audio_flutter.windows.wasapi',
      displayName: 'Windows WASAPI capture',
      platform: 'windows',
      sourceKinds: <PlatformCaptureSourceKind>{
        PlatformCaptureSourceKind.microphone,
        if (systemCaptureSupported) PlatformCaptureSourceKind.systemMix,
        if (processCaptureSupported) ...<PlatformCaptureSourceKind>{
          PlatformCaptureSourceKind.application,
          PlatformCaptureSourceKind.browser,
        },
      },
      capabilities: <PlatformCaptureCapability>{
        if (systemCaptureSupported) PlatformCaptureCapability.systemMix,
        PlatformCaptureCapability.nativeMonotonicClock,
        if (processCaptureSupported) ...<PlatformCaptureCapability>{
          PlatformCaptureCapability.processFiltering,
          PlatformCaptureCapability.applicationFiltering,
        },
      },
    );
  }

  @override
  Future<List<PlatformCaptureSourceInfo>> listCaptureSources() async {
    final List<PlatformAudioInputDevice> inputs = await listAudioInputDevices();
    final bool systemCaptureSupported = await isSystemAudioCaptureSupported();
    final bool processCaptureSupported = await isProcessAudioCaptureSupported();
    final List<PlatformAudioInputDevice> outputs = systemCaptureSupported
        ? await listSystemAudioSources()
        : const <PlatformAudioInputDevice>[];
    final List<PlatformAudioProcess> processes = processCaptureSupported
        ? await listAudioProcesses()
        : const <PlatformAudioProcess>[];

    return <PlatformCaptureSourceInfo>[
      if (inputs.isEmpty)
        const PlatformCaptureSourceInfo(
          sourceId: 'windows.microphone.unavailable',
          kind: PlatformCaptureSourceKind.microphone,
          displayName: 'Microphone',
          availability: PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.microphone,
          timingQuality: PlatformCaptureTimingQuality.nativeMapped,
          availabilityCode: 'windows_microphone_endpoint_unavailable',
          availabilityReason: 'No active WASAPI capture endpoint is available.',
        )
      else
        for (final PlatformAudioInputDevice input in inputs)
          PlatformCaptureSourceInfo(
            sourceId: 'windows.microphone.${Uri.encodeComponent(input.id)}',
            kind: PlatformCaptureSourceKind.microphone,
            displayName: input.label,
            availability: PlatformCaptureSourceAvailability.available,
            captureKind: PlatformCaptureKind.microphone,
            timingQuality: PlatformCaptureTimingQuality.nativeMapped,
            isDefault: input.isDefault,
            nativeSourceId: input.id,
            inputDeviceId: input.id,
          ),
      if (!systemCaptureSupported || outputs.isEmpty)
        PlatformCaptureSourceInfo(
          sourceId: 'windows.system-mix.unavailable',
          kind: PlatformCaptureSourceKind.systemMix,
          displayName: 'System audio mix',
          availability: PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.nativeMapped,
          capabilities: const <PlatformCaptureCapability>{
            PlatformCaptureCapability.systemMix,
          },
          availabilityCode: systemCaptureSupported
              ? 'windows_render_endpoint_unavailable'
              : 'windows_wasapi_loopback_unavailable',
          availabilityReason: systemCaptureSupported
              ? 'No active WASAPI render endpoint is available for loopback.'
              : 'WASAPI loopback capture is unavailable on this host.',
        )
      else
        for (final PlatformAudioInputDevice output in outputs)
          PlatformCaptureSourceInfo(
            sourceId: 'windows.system-mix.${Uri.encodeComponent(output.id)}',
            kind: PlatformCaptureSourceKind.systemMix,
            displayName: output.label,
            availability: PlatformCaptureSourceAvailability.available,
            captureKind: PlatformCaptureKind.systemAudio,
            timingQuality: PlatformCaptureTimingQuality.nativeMapped,
            capabilities: const <PlatformCaptureCapability>{
              PlatformCaptureCapability.systemMix,
            },
            isDefault: output.isDefault,
            nativeSourceId: output.id,
            inputDeviceId: output.id,
          ),
      for (final PlatformAudioProcess process in processes)
        PlatformCaptureSourceInfo(
          sourceId:
              'windows.${_isBrowserProcess(process.bundleId) ? 'browser' : 'application'}.'
              '${process.processId}',
          kind: _isBrowserProcess(process.bundleId)
              ? PlatformCaptureSourceKind.browser
              : PlatformCaptureSourceKind.application,
          displayName: process.bundleId,
          availability: PlatformCaptureSourceAvailability.available,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.nativeMapped,
          capabilities: const <PlatformCaptureCapability>{
            PlatformCaptureCapability.processFiltering,
            PlatformCaptureCapability.applicationFiltering,
          },
          processIds: <int>[process.processId],
          nativeSourceId: '${process.processId}',
          applicationId: process.bundleId,
        ),
      if (!processes.any(
        (PlatformAudioProcess process) => !_isBrowserProcess(process.bundleId),
      ))
        PlatformCaptureSourceInfo(
          sourceId: 'windows.application.unavailable',
          kind: PlatformCaptureSourceKind.application,
          displayName: 'Application audio',
          availability: PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.nativeMapped,
          availabilityCode: processCaptureSupported
              ? 'windows_audio_process_unavailable'
              : 'windows_process_loopback_os_unsupported',
          availabilityReason: processCaptureSupported
              ? 'No active render session exposes a local process ID.'
              : 'Application isolation requires Windows OS build 20348 or newer; Windows 10 22H2 build 19045 supports system-mix capture only.',
        ),
      if (!processes.any(
        (PlatformAudioProcess process) => _isBrowserProcess(process.bundleId),
      ))
        PlatformCaptureSourceInfo(
          sourceId: 'windows.browser.unavailable',
          kind: PlatformCaptureSourceKind.browser,
          displayName: 'Browser audio',
          availability: PlatformCaptureSourceAvailability.unavailable,
          captureKind: PlatformCaptureKind.systemAudio,
          timingQuality: PlatformCaptureTimingQuality.nativeMapped,
          availabilityCode: processCaptureSupported
              ? 'windows_browser_audio_process_unavailable'
              : 'windows_process_loopback_os_unsupported',
          availabilityReason: processCaptureSupported
              ? 'No active browser render session exposes a local process ID.'
              : 'Browser isolation requires Windows OS build 20348 or newer; Windows 10 22H2 build 19045 supports system-mix capture only.',
        ),
    ];
  }

  @override
  Future<List<PlatformAudioInputDevice>> listAudioInputDevices() =>
      _invokeDeviceList(kMethodListAudioInputDevices);

  /// Render endpoints available as system-audio capture targets.
  ///
  /// Not part of the platform contract — the Windows answer to "what can system
  /// capture target", in the same shape [listAudioInputDevices] returns so a
  /// caller can offer both for selection.
  Future<List<PlatformAudioInputDevice>> listSystemAudioSources() =>
      _invokeDeviceList(kMethodListSystemAudioSources);

  @override
  Future<List<PlatformAudioProcess>> listAudioProcesses() async {
    final List<Object?>? reply = await _method.invokeMethod<List<Object?>>(
      kMethodListAudioProcesses,
    );
    return (reply ?? const <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map(decodeAudioProcess)
        .toList(growable: false);
  }

  @override
  Future<PlatformPlaybackSessionInfo> preparePlayback(
    PlatformPlaybackRequest request,
  ) async {
    final Map<Object?, Object?> reply = await _invokeMap(
      kMethodPreparePlayback,
      encodePlaybackRequest(request),
    );
    return decodePlaybackSessionInfo(reply);
  }

  @override
  Stream<PlatformAudioSessionEvent> playbackEvents(int sessionId) =>
      _eventsFor(sessionId);

  @override
  Future<void> startPlayback(int sessionId) => _method.invokeMethod<void>(
    kMethodStartPlayback,
    <String, Object?>{'sessionId': sessionId},
  );

  @override
  Future<void> writePlaybackFrames(
    int sessionId,
    List<PlatformAudioFrame> frames,
  ) => _method.invokeMethod<void>(kMethodWritePlaybackFrames, <String, Object?>{
    'sessionId': sessionId,
    'frames': frames
        .map(
          (PlatformAudioFrame frame) => <String, Object?>{
            'samples': encodeFloat32Le(frame.samples),
          },
        )
        .toList(growable: false),
  });

  @override
  Future<void> finishPlayback(int sessionId) => _method.invokeMethod<void>(
    kMethodFinishPlayback,
    <String, Object?>{'sessionId': sessionId},
  );

  @override
  Future<void> abortPlayback(int sessionId) => _method.invokeMethod<void>(
    kMethodAbortPlayback,
    <String, Object?>{'sessionId': sessionId},
  );

  @override
  Future<void> disposePlayback(int sessionId) => _method.invokeMethod<void>(
    kMethodDisposePlayback,
    <String, Object?>{'sessionId': sessionId},
  );

  Future<List<PlatformAudioInputDevice>> _invokeDeviceList(
    String method,
  ) async {
    final List<Object?>? reply = await _method.invokeMethod<List<Object?>>(
      method,
    );
    return (reply ?? const <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map(decodeInputDevice)
        .toList(growable: false);
  }

  Future<Map<Object?, Object?>> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final Map<Object?, Object?>? reply = await _method
        .invokeMethod<Map<Object?, Object?>>(method, arguments);
    if (reply == null) {
      throw StateError('$method returned no payload');
    }
    return reply;
  }
}

bool _isBrowserProcess(String applicationId) {
  final String value = applicationId.toLowerCase();
  return <String>[
    'chrome',
    'chromium',
    'firefox',
    'msedge',
    'microsoft-edge',
    'brave',
    'opera',
    'vivaldi',
  ].any(value.contains);
}
