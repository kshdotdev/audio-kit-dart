/// How a capture backend established a track's monotonic clock mapping.
enum MonotonicTrackTimingQuality {
  /// The native capture API mapped its own clock to the session clock.
  nativeMapped,

  /// The host synchronized independent clocks after capture began.
  synchronized,

  /// Timing was derived from sample counts because no native clock existed.
  synthesized,
}

/// Maps one captured track onto a shared monotonic session timeline.
///
/// Wall-clock timestamps are deliberately absent. [startOffset] is measured
/// from the zero point identified by [sessionClockId], and sample positions are
/// converted with integer arithmetic so serialization and retries are stable.
final class MonotonicTrackTiming {
  MonotonicTrackTiming({
    required this.trackId,
    required this.clockId,
    required this.sessionClockId,
    required this.sampleRate,
    required this.startOffset,
    this.firstSampleOffset = 0,
    this.quality = MonotonicTrackTimingQuality.nativeMapped,
  }) {
    _requireTimingIdentifier(trackId, 'trackId');
    _requireTimingIdentifier(clockId, 'clockId');
    _requireTimingIdentifier(sessionClockId, 'sessionClockId');
    if (sampleRate <= 0) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'Must be positive.');
    }
    if (startOffset.isNegative) {
      throw ArgumentError.value(
        startOffset,
        'startOffset',
        'Must not be negative.',
      );
    }
    if (firstSampleOffset < 0) {
      throw ArgumentError.value(
        firstSampleOffset,
        'firstSampleOffset',
        'Must not be negative.',
      );
    }
  }

  /// Reads a timing map from durable JSON.
  factory MonotonicTrackTiming.fromJson(Map<String, Object?> json) {
    return MonotonicTrackTiming(
      trackId: _timingRequiredString(json, 'trackId'),
      clockId: _timingRequiredString(json, 'clockId'),
      sessionClockId: _timingRequiredString(json, 'sessionClockId'),
      sampleRate: _timingRequiredInt(json, 'sampleRate'),
      startOffset: Duration(
        microseconds: _timingRequiredInt(json, 'startOffsetMicroseconds'),
      ),
      firstSampleOffset: _timingRequiredInt(json, 'firstSampleOffset'),
      quality: _timingEnumByName(
        MonotonicTrackTimingQuality.values,
        _timingRequiredString(json, 'quality'),
        'quality',
      ),
    );
  }

  /// Stable logical track identifier.
  final String trackId;

  /// Native or synthesized source clock identifier carried by audio frames.
  final String clockId;

  /// Shared monotonic clock used by every track in the capture session.
  final String sessionClockId;

  /// Sample frames per second for this track.
  final int sampleRate;

  /// Position of [firstSampleOffset] on the shared session clock.
  final Duration startOffset;

  /// First source sample offset represented by [startOffset].
  final int firstSampleOffset;

  /// Confidence/source of the clock mapping.
  final MonotonicTrackTimingQuality quality;

  /// Returns the shared-session timestamp for [sampleOffset].
  Duration sessionTimestampForSample(int sampleOffset) {
    if (sampleOffset < firstSampleOffset) {
      throw RangeError.range(
        sampleOffset,
        firstSampleOffset,
        null,
        'sampleOffset',
        'Must not precede the first mapped sample.',
      );
    }
    final int elapsedFrames = sampleOffset - firstSampleOffset;
    return startOffset +
        Duration(
          microseconds:
              (elapsedFrames * Duration.microsecondsPerSecond) ~/ sampleRate,
        );
  }

  /// Converts this mapping to durable JSON.
  Map<String, Object?> toJson() => <String, Object?>{
    'trackId': trackId,
    'clockId': clockId,
    'sessionClockId': sessionClockId,
    'sampleRate': sampleRate,
    'startOffsetMicroseconds': startOffset.inMicroseconds,
    'firstSampleOffset': firstSampleOffset,
    'quality': quality.name,
  };
}

void _requireTimingIdentifier(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
}

String _timingRequiredString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('"$key" must be a non-empty string.');
  }
  return value;
}

int _timingRequiredInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! int) {
    throw FormatException('"$key" must be an integer.');
  }
  return value;
}

T _timingEnumByName<T extends Enum>(List<T> values, String name, String field) {
  for (final T value in values) {
    if (value.name == name) {
      return value;
    }
  }
  throw FormatException('Unknown "$field" value: $name.');
}
