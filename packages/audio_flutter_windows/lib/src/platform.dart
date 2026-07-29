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
/// ## Unsupported request fields
///
/// [PlatformCaptureRequest.processIds] and
/// [PlatformCaptureRequest.rawRecordingPath] are rejected rather than ignored.
/// Per-process loopback needs `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`
/// (Windows 10 20H1+) which this implementation does not yet use, and
/// source-side recording is not implemented natively. Honouring either request
/// silently would hand back audio that does not match what was asked for, so
/// both fail loudly at [prepareCapture]. Both are tracked as follow-ups.
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
      throw UnsupportedError(
        'UnsupportedProcessCapture: audio_flutter_windows cannot target '
        'individual processes; leave processIds empty to capture the render '
        'endpoint mix',
      );
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

  /// Always empty: this implementation taps a render endpoint's mix, so there is
  /// no per-process list to choose from. See the class docs.
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
