import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// Microphone authorization as the platform reports it.
enum AudioMicrophonePermissionStatus {
  /// The user has not been asked yet. [FlutterMicrophonePermission.request]
  /// still shows the prompt.
  notDetermined,

  /// Capture is allowed.
  granted,

  /// The user refused. Only the user can lift this, in system settings, so a
  /// second request is not a prompt.
  denied,

  /// Blocked by policy — a managed device or parental controls. Not
  /// requestable.
  restricted,

  /// The platform exposes no microphone permission gate, so capture is
  /// governed by whatever the host app declares (on Apple platforms, the
  /// `Info.plist` usage description).
  unavailable,
}

/// Whether this status stops a microphone capture from ever receiving audio.
extension AudioMicrophonePermissionStatusX on AudioMicrophonePermissionStatus {
  /// True for [AudioMicrophonePermissionStatus.denied] and
  /// [AudioMicrophonePermissionStatus.restricted].
  ///
  /// [AudioMicrophonePermissionStatus.notDetermined] is deliberately not
  /// blocking: on Apple platforms starting the engine is what triggers the
  /// system prompt.
  bool get blocksCapture =>
      this == AudioMicrophonePermissionStatus.denied ||
      this == AudioMicrophonePermissionStatus.restricted;
}

/// Microphone permission queries for the current platform.
///
/// Preflighting is optional — [FlutterAudioCaptureSource.prepare] fails a
/// microphone capture with `microphone_permission_denied` on its own — but an
/// app that wants to explain the prompt, or to send the user to system
/// settings after a refusal, needs the status before it starts capturing.
final class FlutterMicrophonePermission {
  FlutterMicrophonePermission({AudioFlutterPlatform? platform})
    : _platform = platform ?? AudioFlutterPlatform.instance;

  final AudioFlutterPlatform _platform;

  /// Reads the current status without prompting.
  Future<AudioMicrophonePermissionStatus> status({
    AudioCancellationToken? cancellationToken,
  }) => _query(
    cancellationToken: cancellationToken,
    code: 'platform_microphone_permission_status_failed',
    message: 'Microphone permission status could not be read.',
    call: _platform.microphonePermissionStatus,
  );

  /// Prompts when the status is still
  /// [AudioMicrophonePermissionStatus.notDetermined], then reports the
  /// resulting status.
  ///
  /// A denied or restricted status is returned unchanged: the platform shows
  /// no second prompt.
  Future<AudioMicrophonePermissionStatus> request({
    AudioCancellationToken? cancellationToken,
  }) => _query(
    cancellationToken: cancellationToken,
    code: 'platform_microphone_permission_request_failed',
    message: 'Microphone permission could not be requested.',
    call: _platform.requestMicrophonePermission,
  );

  Future<AudioMicrophonePermissionStatus> _query({
    required AudioCancellationToken? cancellationToken,
    required String code,
    required String message,
    required Future<PlatformMicrophonePermissionStatus> Function() call,
  }) async {
    cancellationToken?.throwIfCancelled();
    try {
      final PlatformMicrophonePermissionStatus status = await call();
      cancellationToken?.throwIfCancelled();
      return _decode(status);
    } on AudioCancelledException {
      rethrow;
    } on UnimplementedError {
      // Federated platforms endorsed before this API existed answer nothing
      // rather than answering "denied".
      return AudioMicrophonePermissionStatus.unavailable;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        error is AudioFailure
            ? error
            : AudioFailure(
                code: code,
                stage: AudioFailureStage.capture,
                message: message,
                retryable: true,
                safeCause: error.runtimeType.toString(),
              ),
        stackTrace,
      );
    }
  }
}

AudioMicrophonePermissionStatus _decode(
  PlatformMicrophonePermissionStatus status,
) => switch (status) {
  PlatformMicrophonePermissionStatus.notDetermined =>
    AudioMicrophonePermissionStatus.notDetermined,
  PlatformMicrophonePermissionStatus.granted =>
    AudioMicrophonePermissionStatus.granted,
  PlatformMicrophonePermissionStatus.denied =>
    AudioMicrophonePermissionStatus.denied,
  PlatformMicrophonePermissionStatus.restricted =>
    AudioMicrophonePermissionStatus.restricted,
};
