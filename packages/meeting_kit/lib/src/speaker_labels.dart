// The overlap assignment, labelling scheme, and turn merging are derived from
// Control Center's `meeting_diarization.dart`, MIT (c) 2026 Samuel Alev.
// See NOTICE.

import 'package:speech_core/speech_core.dart';

/// One line of a meeting transcript.
///
/// Deliberately free of storage concerns: a channel, a label, text, and a time
/// range. Hosts map their own rows onto this to run the helpers below.
final class MeetingTranscriptLine {
  /// Creates a transcript line.
  const MeetingTranscriptLine({
    required this.channel,
    required this.text,
    required this.start,
    required this.end,
    this.speakerLabel,
  });

  /// Which capture channel the line came from.
  final MeetingChannel channel;

  /// The transcribed text.
  final String text;

  /// Offset from the start of the recording.
  final Duration start;

  /// End offset from the start of the recording.
  final Duration end;

  /// Diarized speaker label, such as `Person 1`, when one has been assigned.
  final String? speakerLabel;

  /// Returns a copy with the given overrides.
  MeetingTranscriptLine copyWith({
    String? text,
    Duration? end,
    String? speakerLabel,
  }) => MeetingTranscriptLine(
    channel: channel,
    text: text ?? this.text,
    start: start,
    end: end ?? this.end,
    speakerLabel: speakerLabel ?? this.speakerLabel,
  );
}

/// Which side of the conversation a transcript line came from.
enum MeetingChannel {
  /// The local microphone.
  near,

  /// System or remote audio.
  far,
}

/// The label for a zero-based diarization cluster [index]; `0` becomes
/// `Person 1`.
///
/// Shared by whatever persists speaker identities and by
/// [separateTranscriptBySpeaker], so both use one scheme.
String personLabel(int index) => 'Person ${index + 1}';

/// Returns the speaker whose segment overlaps `[start, end)` the most, or null
/// when nothing overlaps.
///
/// Transcript windows and diarization segments are cut independently, so a
/// window rarely lines up with one segment exactly; the maximum-overlap rule
/// picks the dominant speaker for the window.
String? assignSpeakerByOverlap(
  List<SpeakerSegment> segments,
  Duration start,
  Duration end,
) {
  String? bestSpeaker;
  var bestOverlap = Duration.zero;
  for (final segment in segments) {
    final overlapEnd = end < segment.range.end ? end : segment.range.end;
    final overlapStart = start > segment.range.start
        ? start
        : segment.range.start;
    final overlap = overlapEnd - overlapStart;
    if (overlap > bestOverlap) {
      bestOverlap = overlap;
      bestSpeaker = segment.speakerId;
    }
  }
  return bestSpeaker;
}

/// Re-separates and labels transcript [lines] using diarization [segments] on
/// the diarized [channel].
///
/// Each line on [channel] is tagged with the speaker that dominates it by time
/// overlap, then adjacent fragments sharing a speaker within [mergeGap] are
/// merged into one coherent turn — so a transcript reads as speaker turns
/// rather than choppy windows. Lines on the other channel pass through with
/// their label unchanged but are merged the same way.
///
/// Lines are never split mid-text at a speaker change: batch windows carry no
/// reliable word-level timestamps, so a sub-window cut point cannot be placed;
/// the dominant speaker is used instead.
List<MeetingTranscriptLine> separateTranscriptBySpeaker({
  required List<MeetingTranscriptLine> lines,
  required List<SpeakerSegment> segments,
  required MeetingChannel channel,
  Duration mergeGap = const Duration(seconds: 2),
}) {
  // Without a diarization signal the transcript stands exactly as captured.
  if (lines.isEmpty || segments.isEmpty) {
    return lines;
  }
  final labeled = <MeetingTranscriptLine>[];
  for (final line in lines) {
    if (line.channel != channel) {
      labeled.add(line);
      continue;
    }
    final speaker = assignSpeakerByOverlap(segments, line.start, line.end);
    labeled.add(speaker == null ? line : line.copyWith(speakerLabel: speaker));
  }
  labeled.sort((a, b) => a.start.compareTo(b.start));
  return _mergeTurns(labeled, mergeGap);
}

/// Merges consecutive same-speaker [lines] into coherent turns without
/// diarization.
///
/// Works on a raw live transcript, where lines carry only their channel. Useful
/// so rolling windows read as merged turns and an overlapping window boundary
/// does not show the same words twice.
List<MeetingTranscriptLine> mergeConsecutiveTurns(
  List<MeetingTranscriptLine> lines, {
  Duration mergeGap = const Duration(seconds: 2),
}) {
  if (lines.length <= 1) {
    return lines;
  }
  final sorted = [...lines]..sort((a, b) => a.start.compareTo(b.start));
  return _mergeTurns(sorted, mergeGap);
}

/// Fraction of [candidate]'s word tokens that also appear in [reference], from
/// 0 to 1.
///
/// A value of 1 means the candidate adds nothing new — a window-boundary
/// duplicate.
double tokenContainment(String reference, String candidate) {
  final candidateTokens = _normalizedTokens(candidate);
  if (candidateTokens.isEmpty) {
    return 0;
  }
  final referenceTokens = _normalizedTokens(reference).toSet();
  if (referenceTokens.isEmpty) {
    return 0;
  }
  var hits = 0;
  for (final token in candidateTokens) {
    if (referenceTokens.contains(token)) {
      hits++;
    }
  }
  return hits / candidateTokens.length;
}

List<MeetingTranscriptLine> _mergeTurns(
  List<MeetingTranscriptLine> lines,
  Duration mergeGap,
) {
  if (lines.length <= 1) {
    return lines;
  }
  final out = <MeetingTranscriptLine>[];
  for (final line in lines) {
    if (out.isNotEmpty) {
      final previous = out.last;
      final sameSpeaker =
          previous.channel == line.channel &&
          previous.speakerLabel == line.speakerLabel;
      // Tiny fragments — "okay", "yeah" — belong to the adjacent turn even
      // across a slightly longer gap, so they get a relaxed window.
      final tinyFragment = _visibleLength(line.text) <= 8;
      final limit = tinyFragment ? mergeGap * 2 : mergeGap;
      final contiguous = line.start - previous.end <= limit;
      if (sameSpeaker && contiguous) {
        // Rolling windows overlap, so adjacent windows on one channel sometimes
        // re-transcribe the same words. When one window's tokens are largely
        // contained in the other, keep the longer text instead of concatenating
        // — which would otherwise read "ship it ship it on friday".
        final duplicate =
            tokenContainment(previous.text, line.text) >= 0.67 ||
            tokenContainment(line.text, previous.text) >= 0.67;
        final mergedText = duplicate
            ? (line.text.trim().length > previous.text.trim().length
                  ? line.text
                  : previous.text)
            : _joinTurnText(previous.text, line.text);
        out[out.length - 1] = previous.copyWith(
          text: mergedText,
          end: line.end > previous.end ? line.end : previous.end,
        );
        continue;
      }
    }
    out.add(line);
  }
  return out;
}

int _visibleLength(String text) => text.replaceAll(RegExp(r'\s+'), '').length;

final RegExp _tokenSplit = RegExp(r'[^a-z0-9]+');

List<String> _normalizedTokens(String value) => value
    .toLowerCase()
    .split(_tokenSplit)
    .where((token) => token.isNotEmpty)
    .toList(growable: false);

String _joinTurnText(String left, String right) {
  final start = left.trimRight();
  final end = right.trimLeft();
  if (start.isEmpty) {
    return end;
  }
  if (end.isEmpty) {
    return start;
  }
  return '$start $end';
}
