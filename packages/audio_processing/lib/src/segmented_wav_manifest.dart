import 'package:audio_core/audio_core.dart';

import 'wav.dart';

/// Recorder lifecycle persisted in the sidecar manifest.
enum SegmentedWavRecordingState {
  prepared,
  recording,
  paused,
  finished,
  recovered,
  failed,
}

/// Behavior when the bounded pending-frame queue is full.
enum SegmentedWavQueuePolicy {
  /// Wait for capacity before taking ownership of the new frame.
  wait,

  /// Preserve queued audio and reject the newest frame.
  dropNewest,

  /// Evict queued frames until the newest frame fits.
  dropOldest,

  /// Fail the recorder rather than create an undisclosed recording gap.
  failRecorder,
}

/// Marker written at a stable frame offset in the output timeline.
enum SegmentedWavMarkerType { pause, resume, sourceChange }

/// One finalized or recoverable WAV segment.
final class SegmentedWavSegmentManifest {
  SegmentedWavSegmentManifest({
    required this.segmentId,
    required this.fileName,
    required this.startFrame,
    required this.frameCount,
    required this.finalized,
  }) {
    _requireManifestIdentifier(segmentId, 'segmentId');
    _requireManifestIdentifier(fileName, 'fileName');
    if (startFrame < 0 || frameCount < 0) {
      throw ArgumentError('Segment frame positions must not be negative.');
    }
  }

  factory SegmentedWavSegmentManifest.fromJson(Map<String, Object?> json) {
    return SegmentedWavSegmentManifest(
      segmentId: _manifestRequiredString(json, 'segmentId'),
      fileName: _manifestRequiredString(json, 'fileName'),
      startFrame: _manifestRequiredInt(json, 'startFrame'),
      frameCount: _manifestRequiredInt(json, 'frameCount'),
      finalized: _manifestRequiredBool(json, 'finalized'),
    );
  }

  final String segmentId;
  final String fileName;
  final int startFrame;
  final int frameCount;
  final bool finalized;

  Map<String, Object?> toJson() => <String, Object?>{
    'segmentId': segmentId,
    'fileName': fileName,
    'startFrame': startFrame,
    'frameCount': frameCount,
    'finalized': finalized,
  };
}

/// Durable pause, resume, or capture-source transition.
final class SegmentedWavMarker {
  SegmentedWavMarker({
    required this.markerId,
    required this.type,
    required this.frameOffset,
    this.fromSourceId,
    this.toSourceId,
    this.fromClockId,
    this.toClockId,
    this.reason,
  }) {
    _requireManifestIdentifier(markerId, 'markerId');
    if (frameOffset < 0) {
      throw ArgumentError.value(
        frameOffset,
        'frameOffset',
        'Must not be negative.',
      );
    }
    _requireManifestOptionalText(fromSourceId, 'fromSourceId');
    _requireManifestOptionalText(toSourceId, 'toSourceId');
    _requireManifestOptionalText(fromClockId, 'fromClockId');
    _requireManifestOptionalText(toClockId, 'toClockId');
    _requireManifestOptionalText(reason, 'reason');
    if (type == SegmentedWavMarkerType.sourceChange &&
        (fromSourceId == null ||
            toSourceId == null ||
            fromClockId == null ||
            toClockId == null)) {
      throw ArgumentError(
        'A source-change marker needs both source and clock mappings.',
      );
    }
  }

  factory SegmentedWavMarker.fromJson(Map<String, Object?> json) {
    return SegmentedWavMarker(
      markerId: _manifestRequiredString(json, 'markerId'),
      type: _manifestEnumByName(
        SegmentedWavMarkerType.values,
        _manifestRequiredString(json, 'type'),
        'type',
      ),
      frameOffset: _manifestRequiredInt(json, 'frameOffset'),
      fromSourceId: _manifestOptionalString(json, 'fromSourceId'),
      toSourceId: _manifestOptionalString(json, 'toSourceId'),
      fromClockId: _manifestOptionalString(json, 'fromClockId'),
      toClockId: _manifestOptionalString(json, 'toClockId'),
      reason: _manifestOptionalString(json, 'reason'),
    );
  }

  final String markerId;
  final SegmentedWavMarkerType type;
  final int frameOffset;
  final String? fromSourceId;
  final String? toSourceId;
  final String? fromClockId;
  final String? toClockId;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'markerId': markerId,
    'type': type.name,
    'frameOffset': frameOffset,
    if (fromSourceId != null) 'fromSourceId': fromSourceId,
    if (toSourceId != null) 'toSourceId': toSourceId,
    if (fromClockId != null) 'fromClockId': fromClockId,
    if (toClockId != null) 'toClockId': toClockId,
    if (reason != null) 'reason': reason,
  };
}

/// Versioned crash-recovery sidecar for one segmented track recording.
final class SegmentedWavRecordingManifest {
  SegmentedWavRecordingManifest({
    required this.recordingId,
    required this.sourceId,
    required this.trackId,
    required this.clockId,
    required this.format,
    required this.encoding,
    required this.segmentFrameCount,
    required this.queueCapacityFrames,
    required this.queuePolicy,
    required this.gapPolicy,
    required this.state,
    required this.revision,
    required this.totalFrameCount,
    required this.droppedFrameCount,
    required List<SegmentedWavSegmentManifest> segments,
    required List<SegmentedWavMarker> markers,
    this.failureCode,
    this.failureMessage,
  }) : segments = List<SegmentedWavSegmentManifest>.unmodifiable(segments),
       markers = List<SegmentedWavMarker>.unmodifiable(markers) {
    _requireManifestIdentifier(recordingId, 'recordingId');
    _requireManifestIdentifier(sourceId, 'sourceId');
    _requireManifestIdentifier(trackId, 'trackId');
    _requireManifestIdentifier(clockId, 'clockId');
    if (segmentFrameCount <= 0 || queueCapacityFrames <= 0) {
      throw ArgumentError('Segment and queue frame counts must be positive.');
    }
    if (revision < 0 || totalFrameCount < 0 || droppedFrameCount < 0) {
      throw ArgumentError('Manifest counters must not be negative.');
    }
    _requireManifestOptionalText(failureCode, 'failureCode');
    _requireManifestOptionalText(failureMessage, 'failureMessage');
    if (state == SegmentedWavRecordingState.failed &&
        (failureCode == null || failureMessage == null)) {
      throw ArgumentError('A failed recording must persist its failure.');
    }
    if (state != SegmentedWavRecordingState.failed &&
        (failureCode != null || failureMessage != null)) {
      throw ArgumentError('Only a failed recording may carry a failure.');
    }
    final Set<String> segmentIds = <String>{};
    final Set<String> fileNames = <String>{};
    var previousEnd = 0;
    for (final SegmentedWavSegmentManifest segment in segments) {
      if (!segmentIds.add(segment.segmentId) ||
          !fileNames.add(segment.fileName)) {
        throw ArgumentError('Segment IDs and file names must be unique.');
      }
      if (segment.startFrame < previousEnd) {
        throw ArgumentError('WAV segments must not overlap.');
      }
      previousEnd = segment.startFrame + segment.frameCount;
    }
    if (totalFrameCount < previousEnd) {
      throw ArgumentError(
        'The total frame count cannot precede the final segment.',
      );
    }
    final Set<String> markerIds = <String>{};
    for (final SegmentedWavMarker marker in markers) {
      if (!markerIds.add(marker.markerId)) {
        throw ArgumentError('Marker IDs must be unique.');
      }
    }
  }

  factory SegmentedWavRecordingManifest.fromJson(Map<String, Object?> json) {
    final int version = _manifestRequiredInt(json, 'schemaVersion');
    if (version != schemaVersion) {
      throw FormatException('Unsupported segmented WAV version: $version.');
    }
    final Map<String, Object?> format = _manifestRequiredMap(json, 'format');
    final String sampleFormat = _manifestRequiredString(format, 'sampleFormat');
    if (sampleFormat != AudioSampleFormat.float32.name) {
      throw FormatException('Unsupported sample format: $sampleFormat.');
    }
    return SegmentedWavRecordingManifest(
      recordingId: _manifestRequiredString(json, 'recordingId'),
      sourceId: _manifestRequiredString(json, 'sourceId'),
      trackId: _manifestRequiredString(json, 'trackId'),
      clockId: _manifestRequiredString(json, 'clockId'),
      format: AudioFormat(
        sampleRate: _manifestRequiredInt(format, 'sampleRate'),
        channels: _manifestRequiredInt(format, 'channels'),
      ),
      encoding: _manifestEnumByName(
        WavSampleEncoding.values,
        _manifestRequiredString(json, 'encoding'),
        'encoding',
      ),
      segmentFrameCount: _manifestRequiredInt(json, 'segmentFrameCount'),
      queueCapacityFrames: _manifestRequiredInt(json, 'queueCapacityFrames'),
      queuePolicy: _manifestEnumByName(
        SegmentedWavQueuePolicy.values,
        _manifestRequiredString(json, 'queuePolicy'),
        'queuePolicy',
      ),
      gapPolicy: _manifestEnumByName(
        WavGapPolicy.values,
        _manifestRequiredString(json, 'gapPolicy'),
        'gapPolicy',
      ),
      state: _manifestEnumByName(
        SegmentedWavRecordingState.values,
        _manifestRequiredString(json, 'state'),
        'state',
      ),
      revision: _manifestRequiredInt(json, 'revision'),
      totalFrameCount: _manifestRequiredInt(json, 'totalFrameCount'),
      droppedFrameCount: _manifestRequiredInt(json, 'droppedFrameCount'),
      segments: <SegmentedWavSegmentManifest>[
        for (final Object? item in _manifestRequiredList(json, 'segments'))
          SegmentedWavSegmentManifest.fromJson(
            _manifestAsMap(item, 'segments item'),
          ),
      ],
      markers: <SegmentedWavMarker>[
        for (final Object? item in _manifestRequiredList(json, 'markers'))
          SegmentedWavMarker.fromJson(_manifestAsMap(item, 'markers item')),
      ],
      failureCode: _manifestOptionalString(json, 'failureCode'),
      failureMessage: _manifestOptionalString(json, 'failureMessage'),
    );
  }

  static const int schemaVersion = 1;

  final String recordingId;
  final String sourceId;
  final String trackId;
  final String clockId;
  final AudioFormat format;
  final WavSampleEncoding encoding;
  final int segmentFrameCount;
  final int queueCapacityFrames;
  final SegmentedWavQueuePolicy queuePolicy;
  final WavGapPolicy gapPolicy;
  final SegmentedWavRecordingState state;
  final int revision;
  final int totalFrameCount;
  final int droppedFrameCount;
  final List<SegmentedWavSegmentManifest> segments;
  final List<SegmentedWavMarker> markers;
  final String? failureCode;
  final String? failureMessage;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'recordingId': recordingId,
    'sourceId': sourceId,
    'trackId': trackId,
    'clockId': clockId,
    'format': <String, Object?>{
      'sampleRate': format.sampleRate,
      'channels': format.channels,
      'sampleFormat': format.sampleFormat.name,
    },
    'encoding': encoding.name,
    'segmentFrameCount': segmentFrameCount,
    'queueCapacityFrames': queueCapacityFrames,
    'queuePolicy': queuePolicy.name,
    'gapPolicy': gapPolicy.name,
    'state': state.name,
    'revision': revision,
    'totalFrameCount': totalFrameCount,
    'droppedFrameCount': droppedFrameCount,
    'segments': <Map<String, Object?>>[
      for (final SegmentedWavSegmentManifest segment in segments)
        segment.toJson(),
    ],
    'markers': <Map<String, Object?>>[
      for (final SegmentedWavMarker marker in markers) marker.toJson(),
    ],
    if (failureCode != null) 'failureCode': failureCode,
    if (failureMessage != null) 'failureMessage': failureMessage,
  };
}

void _requireManifestIdentifier(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
}

void _requireManifestOptionalText(String? value, String name) {
  if (value != null) {
    _requireManifestIdentifier(value, name);
  }
}

String _manifestRequiredString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('"$key" must be a non-empty string.');
  }
  return value;
}

String? _manifestOptionalString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('"$key" must be a non-empty string when present.');
  }
  return value;
}

int _manifestRequiredInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! int) {
    throw FormatException('"$key" must be an integer.');
  }
  return value;
}

bool _manifestRequiredBool(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! bool) {
    throw FormatException('"$key" must be a boolean.');
  }
  return value;
}

List<Object?> _manifestRequiredList(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! List<Object?>) {
    throw FormatException('"$key" must be a JSON array.');
  }
  return value;
}

Map<String, Object?> _manifestRequiredMap(
  Map<String, Object?> json,
  String key,
) => _manifestAsMap(json[key], key);

Map<String, Object?> _manifestAsMap(Object? value, String name) {
  if (value is! Map<Object?, Object?>) {
    throw FormatException('"$name" must be a JSON object.');
  }
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    final Object? key = entry.key;
    if (key is! String) {
      throw FormatException('"$name" must have string keys.');
    }
    result[key] = entry.value;
  }
  return result;
}

T _manifestEnumByName<T extends Enum>(
  List<T> values,
  String name,
  String field,
) {
  for (final T value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw FormatException('Unknown "$field" value: $name.');
}
