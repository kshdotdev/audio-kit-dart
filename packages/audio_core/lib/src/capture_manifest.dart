import 'format.dart';
import 'track_timing.dart';

/// Capture shape requested by the host before a recording starts.
enum RequestedAudioCaptureMode {
  /// Record only the selected microphone.
  microphone,

  /// Record only system output audio.
  systemAudio,

  /// Record microphone and system audio as independent tracks.
  microphoneAndSystemAudio,
}

/// Provider-neutral kind of physical or logical capture source.
enum AudioCaptureSourceKind {
  microphone,
  systemAudio,
  processAudio,
  mixed,
  unknown,
}

/// Stable identity of the source that produced a captured track.
final class AudioCaptureSourceIdentity {
  AudioCaptureSourceIdentity({
    required this.sourceId,
    required this.kind,
    this.providerId,
    this.nativeSourceId,
    this.displayName,
  }) {
    _requireIdentifier(sourceId, 'sourceId');
    _requireOptionalText(providerId, 'providerId');
    _requireOptionalText(nativeSourceId, 'nativeSourceId');
    _requireOptionalText(displayName, 'displayName');
  }

  /// Reads a source identity from its durable JSON representation.
  factory AudioCaptureSourceIdentity.fromJson(Map<String, Object?> json) {
    return AudioCaptureSourceIdentity(
      sourceId: _requiredString(json, 'sourceId'),
      kind: _enumByName(
        AudioCaptureSourceKind.values,
        _requiredString(json, 'kind'),
        'kind',
      ),
      providerId: _optionalString(json, 'providerId'),
      nativeSourceId: _optionalString(json, 'nativeSourceId'),
      displayName: _optionalString(json, 'displayName'),
    );
  }

  /// Stable application-level source ID used on emitted audio frames.
  final String sourceId;

  /// Physical or logical source category.
  final AudioCaptureSourceKind kind;

  /// Adapter or provider that resolved this source, when applicable.
  final String? providerId;

  /// Platform identifier used to reopen the same source, when available.
  final String? nativeSourceId;

  /// Human-readable source label captured for diagnostics.
  final String? displayName;

  /// Converts this value to a durable, provider-neutral JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'kind': kind.name,
    if (providerId != null) 'providerId': providerId,
    if (nativeSourceId != null) 'nativeSourceId': nativeSourceId,
    if (displayName != null) 'displayName': displayName,
  };
}

/// One independently persisted track produced by a capture session.
final class CapturedAudioTrackManifest {
  CapturedAudioTrackManifest({
    required this.trackId,
    required this.artifactId,
    required this.source,
    required this.format,
    required this.startOffset,
    this.frameCount,
    this.timing,
  }) {
    _requireIdentifier(trackId, 'trackId');
    _requireIdentifier(artifactId, 'artifactId');
    if (startOffset.isNegative) {
      throw ArgumentError.value(
        startOffset,
        'startOffset',
        'Must not be negative.',
      );
    }
    if (frameCount != null && frameCount! < 0) {
      throw ArgumentError.value(
        frameCount,
        'frameCount',
        'Must not be negative.',
      );
    }
    if (timing != null) {
      if (timing!.trackId != trackId) {
        throw ArgumentError('Track timing belongs to another track.');
      }
      if (timing!.sampleRate != format.sampleRate) {
        throw ArgumentError('Track timing sample rate must match the format.');
      }
      if (timing!.startOffset != startOffset) {
        throw ArgumentError(
          'Track timing and manifest start offsets must match.',
        );
      }
    }
  }

  /// Reads a captured track from its durable JSON representation.
  factory CapturedAudioTrackManifest.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> formatJson = _requiredMap(json, 'format');
    final String sampleFormat = _requiredString(formatJson, 'sampleFormat');
    if (sampleFormat != AudioSampleFormat.float32.name) {
      throw FormatException('Unsupported sample format: $sampleFormat.');
    }
    return CapturedAudioTrackManifest(
      trackId: _requiredString(json, 'trackId'),
      artifactId: _requiredString(json, 'artifactId'),
      source: AudioCaptureSourceIdentity.fromJson(_requiredMap(json, 'source')),
      format: AudioFormat(
        sampleRate: _requiredInt(formatJson, 'sampleRate'),
        channels: _requiredInt(formatJson, 'channels'),
      ),
      startOffset: Duration(
        microseconds: _requiredInt(json, 'startOffsetMicroseconds'),
      ),
      frameCount: _optionalInt(json, 'frameCount'),
      timing: json['timing'] == null
          ? null
          : MonotonicTrackTiming.fromJson(_requiredMap(json, 'timing')),
    );
  }

  /// Stable logical track ID used on emitted audio frames.
  final String trackId;

  /// Stable ID of the persisted audio artifact containing this track.
  final String artifactId;

  /// Source that actually produced this track.
  final AudioCaptureSourceIdentity source;

  /// Decoded PCM format represented by the artifact.
  final AudioFormat format;

  /// Track start relative to the session's monotonic zero point.
  final Duration startOffset;

  /// Number of captured sample frames, when finalization established it.
  final int? frameCount;

  /// Mapping from source samples to the shared monotonic session clock.
  final MonotonicTrackTiming? timing;

  /// Converts this value to a durable JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'trackId': trackId,
    'artifactId': artifactId,
    'source': source.toJson(),
    'format': <String, Object?>{
      'sampleRate': format.sampleRate,
      'channels': format.channels,
      'sampleFormat': format.sampleFormat.name,
    },
    'startOffsetMicroseconds': startOffset.inMicroseconds,
    if (frameCount != null) 'frameCount': frameCount,
    if (timing != null) 'timing': timing!.toJson(),
  };
}

/// Structured explanation for a capture that did not match the request.
final class AudioCaptureDegradationReason {
  AudioCaptureDegradationReason({required this.code, required this.message}) {
    _requireIdentifier(code, 'code');
    _requireIdentifier(message, 'message');
  }

  /// Reads a degradation reason from durable JSON.
  factory AudioCaptureDegradationReason.fromJson(Map<String, Object?> json) {
    return AudioCaptureDegradationReason(
      code: _requiredString(json, 'code'),
      message: _requiredString(json, 'message'),
    );
  }

  /// Stable machine-readable reason code.
  final String code;

  /// User-safe explanation of the degraded capture.
  final String message;

  /// Converts this value to a durable JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'message': message,
  };
}

/// Durable description of the audio artifacts produced by one capture.
final class AudioCaptureSessionManifest {
  AudioCaptureSessionManifest({
    required this.sessionId,
    required this.requestedMode,
    required List<CapturedAudioTrackManifest> tracks,
    this.degradationReason,
  }) : tracks = List<CapturedAudioTrackManifest>.unmodifiable(tracks) {
    _requireIdentifier(sessionId, 'sessionId');
    final Set<String> trackIds = <String>{};
    final Set<String> artifactIds = <String>{};
    for (final CapturedAudioTrackManifest track in tracks) {
      if (!trackIds.add(track.trackId)) {
        throw ArgumentError.value(
          track.trackId,
          'tracks',
          'Track IDs must be unique.',
        );
      }
      if (!artifactIds.add(track.artifactId)) {
        throw ArgumentError.value(
          track.artifactId,
          'tracks',
          'Artifact IDs must be unique.',
        );
      }
    }
  }

  /// Reads and validates a versioned capture manifest.
  factory AudioCaptureSessionManifest.fromJson(Map<String, Object?> json) {
    final int version = _requiredInt(json, 'schemaVersion');
    if (version != schemaVersion) {
      throw FormatException('Unsupported capture manifest version: $version.');
    }
    final Object? rawTracks = json['tracks'];
    if (rawTracks is! List<Object?>) {
      throw const FormatException('"tracks" must be a JSON array.');
    }
    final Object? rawDegradation = json['degradationReason'];
    return AudioCaptureSessionManifest(
      sessionId: _requiredString(json, 'sessionId'),
      requestedMode: _enumByName(
        RequestedAudioCaptureMode.values,
        _requiredString(json, 'requestedMode'),
        'requestedMode',
      ),
      tracks: <CapturedAudioTrackManifest>[
        for (final Object? item in rawTracks)
          CapturedAudioTrackManifest.fromJson(_asMap(item, 'tracks item')),
      ],
      degradationReason: rawDegradation == null
          ? null
          : AudioCaptureDegradationReason.fromJson(
              _asMap(rawDegradation, 'degradationReason'),
            ),
    );
  }

  /// Current durable JSON schema version.
  static const int schemaVersion = 1;

  /// Stable ID for the complete capture session.
  final String sessionId;

  /// Capture shape originally requested by the host.
  final RequestedAudioCaptureMode requestedMode;

  /// Independently persisted tracks that were actually captured.
  final List<CapturedAudioTrackManifest> tracks;

  /// Why the actual tracks differ from [requestedMode], when degraded.
  final AudioCaptureDegradationReason? degradationReason;

  /// Converts this manifest to its versioned durable JSON representation.
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'sessionId': sessionId,
    'requestedMode': requestedMode.name,
    'tracks': <Map<String, Object?>>[
      for (final CapturedAudioTrackManifest track in tracks) track.toJson(),
    ],
    if (degradationReason != null)
      'degradationReason': degradationReason!.toJson(),
  };
}

void _requireIdentifier(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
}

void _requireOptionalText(String? value, String name) {
  if (value != null) {
    _requireIdentifier(value, name);
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('"$key" must be a non-empty string.');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('"$key" must be a non-empty string when present.');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! int) {
    throw FormatException('"$key" must be an integer.');
  }
  return value;
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! int) {
    throw FormatException('"$key" must be an integer when present.');
  }
  return value;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) =>
    _asMap(json[key], key);

Map<String, Object?> _asMap(Object? value, String name) {
  if (value is! Map<Object?, Object?>) {
    throw FormatException('"$name" must be a JSON object.');
  }
  try {
    return value.cast<String, Object?>();
  } on TypeError {
    throw FormatException('"$name" must have string keys.');
  }
}

T _enumByName<T extends Enum>(List<T> values, String name, String field) {
  for (final T value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw FormatException('Unknown "$field" value: $name.');
}
