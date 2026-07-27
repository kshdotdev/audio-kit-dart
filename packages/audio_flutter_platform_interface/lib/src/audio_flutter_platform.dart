import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'messages.dart';

/// Federated platform boundary used by the app-facing audio_flutter package.
abstract class AudioFlutterPlatform extends PlatformInterface {
  AudioFlutterPlatform() : super(token: _token);

  static final Object _token = Object();
  static AudioFlutterPlatform _instance = _UnsupportedAudioFlutterPlatform();

  static AudioFlutterPlatform get instance => _instance;

  static set instance(AudioFlutterPlatform value) {
    PlatformInterface.verifyToken(value, _token);
    _instance = value;
  }

  Future<PlatformCaptureSessionInfo> prepareCapture(
    PlatformCaptureRequest request,
  );

  Stream<PlatformAudioSessionEvent> captureEvents(int sessionId);

  Future<void> startCapture(int sessionId);

  /// Pulls at most [maxFrames], waiting no longer than [timeout].
  Future<PlatformAudioFrameBatch> readCaptureFrames(
    int sessionId, {
    int maxFrames = 8,
    Duration timeout = const Duration(milliseconds: 500),
  });

  Future<void> stopCapture(int sessionId);

  Future<void> abortCapture(int sessionId);

  Future<void> disposeCapture(int sessionId);

  Future<bool> isSystemAudioCaptureSupported();

  Future<bool> requestSystemAudioCapturePermission();

  Future<List<PlatformAudioInputDevice>> listAudioInputDevices();

  Future<List<PlatformAudioProcess>> listAudioProcesses();

  Future<PlatformPlaybackSessionInfo> preparePlayback(
    PlatformPlaybackRequest request,
  );

  Stream<PlatformAudioSessionEvent> playbackEvents(int sessionId);

  Future<void> startPlayback(int sessionId);

  Future<void> writePlaybackFrames(
    int sessionId,
    List<PlatformAudioFrame> frames,
  );

  Future<void> finishPlayback(int sessionId);

  Future<void> abortPlayback(int sessionId);

  Future<void> disposePlayback(int sessionId);
}

final class _UnsupportedAudioFlutterPlatform extends AudioFlutterPlatform {
  Never _unsupported() => throw UnsupportedError(
    'audio_flutter has no implementation on this platform',
  );

  @override
  Future<void> abortCapture(int sessionId) async => _unsupported();

  @override
  Future<void> abortPlayback(int sessionId) async => _unsupported();

  @override
  Stream<PlatformAudioSessionEvent> captureEvents(int sessionId) =>
      const Stream<PlatformAudioSessionEvent>.empty();

  @override
  Future<void> disposeCapture(int sessionId) async => _unsupported();

  @override
  Future<void> disposePlayback(int sessionId) async => _unsupported();

  @override
  Future<void> finishPlayback(int sessionId) async => _unsupported();

  @override
  Future<bool> isSystemAudioCaptureSupported() async => false;

  @override
  Future<List<PlatformAudioInputDevice>> listAudioInputDevices() async =>
      const <PlatformAudioInputDevice>[];

  @override
  Future<List<PlatformAudioProcess>> listAudioProcesses() async =>
      const <PlatformAudioProcess>[];

  @override
  Stream<PlatformAudioSessionEvent> playbackEvents(int sessionId) =>
      const Stream<PlatformAudioSessionEvent>.empty();

  @override
  Future<PlatformCaptureSessionInfo> prepareCapture(
    PlatformCaptureRequest request,
  ) async => _unsupported();

  @override
  Future<PlatformPlaybackSessionInfo> preparePlayback(
    PlatformPlaybackRequest request,
  ) async => _unsupported();

  @override
  Future<PlatformAudioFrameBatch> readCaptureFrames(
    int sessionId, {
    int maxFrames = 8,
    Duration timeout = const Duration(milliseconds: 500),
  }) async => _unsupported();

  @override
  Future<bool> requestSystemAudioCapturePermission() async => false;

  @override
  Future<void> startCapture(int sessionId) async => _unsupported();

  @override
  Future<void> startPlayback(int sessionId) async => _unsupported();

  @override
  Future<void> stopCapture(int sessionId) async => _unsupported();

  @override
  Future<void> writePlaybackFrames(
    int sessionId,
    List<PlatformAudioFrame> frames,
  ) async => _unsupported();
}
