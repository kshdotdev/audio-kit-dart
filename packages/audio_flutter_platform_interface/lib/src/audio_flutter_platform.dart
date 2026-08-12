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

  /// Whether this platform can capture system audio at all.
  ///
  /// A capability answer, not a permission answer: `true` means the mechanism
  /// exists on this OS version, never that a capture will produce audio. See
  /// [requestSystemAudioCapturePermission] for why the grant is advisory.
  Future<bool> isSystemAudioCaptureSupported();

  /// Requests the system-audio capture grant, reporting whether it appears to
  /// be held.
  ///
  /// Advisory. On macOS the grant is enforced when audio is delivered rather
  /// than when the capture is created, so an ungranted process can still build
  /// a valid-looking capture that is fed silence — this may report `true`
  /// optimistically. The authoritative signal is capture health: a session
  /// that reaches a running phase with `receivingAudio` false is silent. On
  /// macOS a process-scoped tap whose target has not played audio yet stays
  /// armed and reports `SystemCaptureAwaitingAppAudio` until the app's first
  /// sound; `SystemCaptureDead` is reserved for a chain whose device ran but
  /// delivered nothing through conversion. Treat `false` as conclusive, treat
  /// `true` as a hint, and keep observing session events after the capture
  /// starts.
  Future<bool> requestSystemAudioCapturePermission();

  /// Reports the microphone authorization without prompting.
  ///
  /// Implementations added this after 0.1.0, so the default body throws
  /// [UnimplementedError] rather than widening the abstract surface: a
  /// platform package built against the older contract keeps compiling, and
  /// callers treat the throw as "this platform has no permission gate".
  Future<PlatformMicrophonePermissionStatus> microphonePermissionStatus() =>
      throw UnimplementedError(
        'microphonePermissionStatus() is not implemented on this platform',
      );

  /// Prompts for microphone access when the status is still undetermined and
  /// reports the resulting status.
  ///
  /// Never re-prompts: a denied or restricted status is returned unchanged,
  /// because only the user (or an administrator) can lift it. Carries the same
  /// [UnimplementedError] default as [microphonePermissionStatus].
  Future<PlatformMicrophonePermissionStatus> requestMicrophonePermission() =>
      throw UnimplementedError(
        'requestMicrophonePermission() is not implemented on this platform',
      );

  /// Destroys private capture devices this plugin leaked in an earlier run,
  /// returning how many were reclaimed.
  ///
  /// A process killed mid-capture cannot unwind its own devices. Same
  /// [UnimplementedError] default as the microphone permission pair.
  Future<int> cleanupOrphanedCaptureDevices() => throw UnimplementedError(
    'cleanupOrphanedCaptureDevices() is not implemented on this platform',
  );

  /// Describes the normalized capture adapter implemented by this platform.
  ///
  /// The default preserves source compatibility with platform packages built
  /// before normalized discovery existed and reports no capture support.
  Future<PlatformCaptureBackendInfo> captureBackendInfo() async =>
      const PlatformCaptureBackendInfo(
        backendId: 'audio_flutter.unsupported',
        displayName: 'Unsupported Flutter capture backend',
        platform: 'unsupported',
        sourceKinds: <PlatformCaptureSourceKind>{},
      );

  /// Lists capability-checked normalized sources, including explicit
  /// unavailable descriptors for known-but-unimplemented native features.
  Future<List<PlatformCaptureSourceInfo>> listCaptureSources() async =>
      const <PlatformCaptureSourceInfo>[];

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
