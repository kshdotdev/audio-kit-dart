import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// A process visible to the platform audio server.
final class AudioCaptureProcess {
  const AudioCaptureProcess({
    required this.processId,
    required this.bundleId,
    required this.isProducingAudio,
  });

  final int processId;
  final String bundleId;
  final bool isProducingAudio;
}

/// Platform capability and permission helpers for system-audio capture.
final class FlutterSystemAudio {
  FlutterSystemAudio({AudioFlutterPlatform? platform})
    : _platform = platform ?? AudioFlutterPlatform.instance;

  final AudioFlutterPlatform _platform;

  Future<bool> get isSupported async {
    try {
      return await _platform.isSystemAudioCaptureSupported();
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _systemAudioFailure(
          error,
          code: 'platform_system_audio_capability_failed',
          message: 'System-audio support could not be determined.',
        ),
        stackTrace,
      );
    }
  }

  Future<bool> requestPermission({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    try {
      final bool granted = await _platform
          .requestSystemAudioCapturePermission();
      cancellationToken?.throwIfCancelled();
      return granted;
    } on AudioCancelledException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _systemAudioFailure(
          error,
          code: 'platform_system_audio_permission_failed',
          message: 'System-audio permission could not be requested.',
        ),
        stackTrace,
      );
    }
  }

  Future<List<AudioCaptureProcess>> listProcesses({
    AudioCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    try {
      final List<PlatformAudioProcess> processes = await _platform
          .listAudioProcesses();
      cancellationToken?.throwIfCancelled();
      return <AudioCaptureProcess>[
        for (final PlatformAudioProcess process in processes)
          AudioCaptureProcess(
            processId: process.processId,
            bundleId: process.bundleId,
            isProducingAudio: process.isProducingAudio,
          ),
      ];
    } on AudioCancelledException {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _systemAudioFailure(
          error,
          code: 'platform_audio_processes_failed',
          message: 'Audio-producing processes could not be listed.',
        ),
        stackTrace,
      );
    }
  }
}

AudioFailure _systemAudioFailure(
  Object error, {
  required String code,
  required String message,
}) => error is AudioFailure
    ? error
    : AudioFailure(
        code: code,
        stage: AudioFailureStage.capture,
        message: message,
        retryable: true,
        safeCause: error.runtimeType.toString(),
      );
