/// One decoded window of a track's audio, positioned on that track's timeline.
final class TranscriptSegment {
  /// Creates a segment.
  TranscriptSegment({
    required this.trackId,
    required this.text,
    required this.start,
    required this.end,
  }) {
    if (trackId.trim().isEmpty) {
      throw ArgumentError.value(trackId, 'trackId', 'Must not be empty.');
    }
    if (start.isNegative) {
      throw ArgumentError.value(start, 'start', 'Must not be negative.');
    }
    if (end < start) {
      throw ArgumentError.value(end, 'end', 'Must not precede start.');
    }
  }

  /// Track that produced this segment, carried through from the audio frames.
  final String trackId;

  /// Decoded text, already trimmed and filtered.
  final String text;

  /// Inclusive start offset from the track's first sample.
  final Duration start;

  /// Exclusive end offset from the track's first sample.
  final Duration end;

  /// Length of the window this segment was decoded from.
  Duration get duration => end - start;

  @override
  String toString() =>
      'TranscriptSegment($trackId, ${start.inMilliseconds}–'
      '${end.inMilliseconds}ms, "$text")';
}
