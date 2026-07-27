import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    swiftOut:
        'darwin/audio_flutter_darwin/Sources/audio_flutter_darwin/Messages.g.swift',
    dartPackageName: 'audio_flutter_darwin',
  ),
)
enum CaptureKindMessage { microphone, systemAudio }

enum CaptureOverflowPolicyMessage { dropOldest, dropNewest, failCapture }

enum AudioSessionPhaseMessage {
  prepared,
  starting,
  running,
  interrupted,
  stopping,
  stopped,
  failed,
}

class PcmFormatMessage {
  PcmFormatMessage({required this.sampleRate, required this.channelCount});

  int sampleRate;
  int channelCount;
}

class CaptureRequestMessage {
  CaptureRequestMessage({
    required this.kind,
    required this.outputFormat,
    required this.frameDurationMicros,
    required this.maxBufferedDurationMicros,
    required this.overflowPolicy,
    required this.processIds,
    this.inputDeviceId,
    this.rawRecordingPath,
  });

  CaptureKindMessage kind;
  PcmFormatMessage outputFormat;
  int frameDurationMicros;
  int maxBufferedDurationMicros;
  CaptureOverflowPolicyMessage overflowPolicy;
  List<int> processIds;
  String? inputDeviceId;
  String? rawRecordingPath;
}

class CaptureSessionInfoMessage {
  CaptureSessionInfoMessage({
    required this.sessionId,
    required this.sourceId,
    required this.trackId,
    required this.clockId,
    required this.format,
  });

  int sessionId;
  String sourceId;
  String trackId;
  String clockId;
  PcmFormatMessage format;
}

class AudioFrameMessage {
  AudioFrameMessage({
    required this.sessionId,
    required this.sequence,
    required this.sampleOffset,
    required this.timestampMicros,
    required this.float32Samples,
    required this.droppedFramesBefore,
  });

  int sessionId;
  int sequence;
  int sampleOffset;
  int timestampMicros;
  Uint8List float32Samples;
  int droppedFramesBefore;
}

class AudioFrameBatchMessage {
  AudioFrameBatchMessage({required this.frames, required this.endOfStream});

  List<AudioFrameMessage> frames;
  bool endOfStream;
}

class AudioSessionEventMessage {
  AudioSessionEventMessage({
    required this.sessionId,
    required this.phase,
    this.code,
    this.message,
    this.receivingAudio,
    this.callbackCount,
  });

  int sessionId;
  AudioSessionPhaseMessage phase;
  String? code;
  String? message;
  bool? receivingAudio;
  int? callbackCount;
}

class AudioProcessMessage {
  AudioProcessMessage({
    required this.processId,
    required this.bundleId,
    required this.isProducingAudio,
  });

  int processId;
  String bundleId;
  bool isProducingAudio;
}

class AudioInputDeviceMessage {
  AudioInputDeviceMessage({
    required this.id,
    required this.label,
    required this.isDefault,
  });

  String id;
  String label;
  bool isDefault;
}

class PlaybackRequestMessage {
  PlaybackRequestMessage({
    required this.inputFormat,
    required this.maxBufferedDurationMicros,
  });

  PcmFormatMessage inputFormat;
  int maxBufferedDurationMicros;
}

class PlaybackSessionInfoMessage {
  PlaybackSessionInfoMessage({
    required this.sessionId,
    required this.clockId,
    required this.format,
  });

  int sessionId;
  String clockId;
  PcmFormatMessage format;
}

@HostApi()
abstract class DarwinAudioHostApi {
  @async
  CaptureSessionInfoMessage prepareCapture(CaptureRequestMessage request);

  @async
  void startCapture(int sessionId);

  @async
  AudioFrameBatchMessage readCaptureFrames(
    int sessionId,
    int maxFrames,
    int timeoutMillis,
  );

  @async
  void stopCapture(int sessionId);

  @async
  void abortCapture(int sessionId);

  @async
  void disposeCapture(int sessionId);

  @async
  bool isSystemAudioCaptureSupported();

  @async
  bool requestSystemAudioCapturePermission();

  @async
  List<AudioInputDeviceMessage> listAudioInputDevices();

  @async
  List<AudioProcessMessage> listAudioProcesses();

  @async
  PlaybackSessionInfoMessage preparePlayback(PlaybackRequestMessage request);

  @async
  void startPlayback(int sessionId);

  @async
  void writePlaybackFrames(int sessionId, List<AudioFrameMessage> frames);

  @async
  void finishPlayback(int sessionId);

  @async
  void abortPlayback(int sessionId);

  @async
  void disposePlayback(int sessionId);
}

@EventChannelApi()
abstract class DarwinAudioEventChannelApi {
  AudioSessionEventMessage sessionEvents();
}
