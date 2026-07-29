// Ported from Control Center's meeting_diarization_test.dart,
// MIT (c) 2026 Samuel Alev. See NOTICE.

import 'package:meeting_kit/meeting_kit.dart';
import 'package:speech_core/speech_core.dart';
import 'package:test/test.dart';

Duration ms(int value) => Duration(milliseconds: value);

SpeakerSegment segment(String speaker, int startMs, int endMs) =>
    SpeakerSegment(
      speakerId: speaker,
      range: SpeechTimeRange(start: ms(startMs), end: ms(endMs)),
    );

MeetingTranscriptLine line(
  String text,
  int startMs,
  int endMs, {
  MeetingChannel channel = MeetingChannel.far,
  String? label,
}) => MeetingTranscriptLine(
  channel: channel,
  text: text,
  start: ms(startMs),
  end: ms(endMs),
  speakerLabel: label,
);

void main() {
  group('personLabel', () {
    test('is one-based', () {
      expect(personLabel(0), 'Person 1');
      expect(personLabel(3), 'Person 4');
    });
  });

  group('assignSpeakerByOverlap', () {
    final spans = [
      segment('Person 1', 0, 1000),
      segment('Person 2', 1000, 3000),
    ];

    test('picks the dominant speaker by overlap', () {
      expect(assignSpeakerByOverlap(spans, ms(900), ms(2500)), 'Person 2');
      expect(assignSpeakerByOverlap(spans, ms(0), ms(900)), 'Person 1');
    });

    test('returns null when nothing overlaps', () {
      expect(assignSpeakerByOverlap(spans, ms(5000), ms(6000)), isNull);
    });

    test('returns null for an empty segment list', () {
      expect(assignSpeakerByOverlap(const [], ms(0), ms(100)), isNull);
    });

    test('ignores a zero-length touch', () {
      expect(assignSpeakerByOverlap(spans, ms(1000), ms(1000)), isNull);
    });
  });

  group('tokenContainment', () {
    test('reports full containment', () {
      expect(tokenContainment('ship it on friday', 'ship it'), 1.0);
    });

    test('reports partial containment', () {
      expect(tokenContainment('ship it', 'ship them'), closeTo(0.5, 1e-9));
    });

    test('is zero for empty input', () {
      expect(tokenContainment('ship it', ''), 0);
      expect(tokenContainment('', 'ship it'), 0);
    });

    test('ignores case and punctuation', () {
      expect(tokenContainment('Ship it!', 'ship, IT'), 1.0);
    });
  });

  group('separateTranscriptBySpeaker', () {
    test('labels far-channel lines by dominant speaker', () {
      final result = separateTranscriptBySpeaker(
        lines: [line('hello there', 0, 900), line('quite so', 1200, 2500)],
        segments: [
          segment('Person 1', 0, 1000),
          segment('Person 2', 1000, 3000),
        ],
        channel: MeetingChannel.far,
      );

      expect(result.map((l) => l.speakerLabel), ['Person 1', 'Person 2']);
    });

    test('leaves the other channel untouched', () {
      final result = separateTranscriptBySpeaker(
        lines: [line('my words', 0, 900, channel: MeetingChannel.near)],
        segments: [segment('Person 1', 0, 1000)],
        channel: MeetingChannel.far,
      );

      expect(result.single.speakerLabel, isNull);
      expect(result.single.channel, MeetingChannel.near);
    });

    test('merges adjacent same-speaker fragments into one turn', () {
      final result = separateTranscriptBySpeaker(
        lines: [line('we should', 0, 500), line('ship on friday', 700, 1000)],
        segments: [segment('Person 1', 0, 1000)],
        channel: MeetingChannel.far,
      );

      expect(result, hasLength(1));
      expect(result.single.text, 'we should ship on friday');
      expect(result.single.end, ms(1000));
    });

    test('keeps only the longer text for a window-boundary duplicate', () {
      final result = separateTranscriptBySpeaker(
        lines: [line('ship it', 0, 500), line('ship it on friday', 600, 1000)],
        segments: [segment('Person 1', 0, 1000)],
        channel: MeetingChannel.far,
      );

      expect(result, hasLength(1));
      expect(result.single.text, 'ship it on friday');
    });

    test('does not merge across a speaker change', () {
      final result = separateTranscriptBySpeaker(
        lines: [line('hello', 0, 500), line('goodbye', 1200, 2000)],
        segments: [
          segment('Person 1', 0, 900),
          segment('Person 2', 1000, 3000),
        ],
        channel: MeetingChannel.far,
      );

      expect(result, hasLength(2));
      expect(result.map((l) => l.speakerLabel), ['Person 1', 'Person 2']);
    });

    test('does not merge across a long gap', () {
      final result = separateTranscriptBySpeaker(
        lines: [
          line('first thought entirely', 0, 500),
          line('second thought entirely', 9000, 9500),
        ],
        segments: [segment('Person 1', 0, 10000)],
        channel: MeetingChannel.far,
      );

      expect(result, hasLength(2));
    });

    test('glues a tiny fragment across a wider gap', () {
      final result = separateTranscriptBySpeaker(
        lines: [
          line('are we agreed on this', 0, 500),
          line('yeah', 3200, 3400),
        ],
        segments: [segment('Person 1', 0, 5000)],
        channel: MeetingChannel.far,
      );

      expect(result, hasLength(1));
      expect(result.single.text, 'are we agreed on this yeah');
    });

    test('passes the transcript through without a diarization signal', () {
      final lines = [line('hello', 0, 500)];

      expect(
        separateTranscriptBySpeaker(
          lines: lines,
          segments: const [],
          channel: MeetingChannel.far,
        ),
        same(lines),
      );
      expect(
        separateTranscriptBySpeaker(
          lines: const [],
          segments: [segment('Person 1', 0, 100)],
          channel: MeetingChannel.far,
        ),
        isEmpty,
      );
    });

    test('sorts lines before merging', () {
      final result = separateTranscriptBySpeaker(
        lines: [line('ship on friday', 700, 1000), line('we should', 0, 500)],
        segments: [segment('Person 1', 0, 1000)],
        channel: MeetingChannel.far,
      );

      expect(result.single.text, 'we should ship on friday');
    });
  });

  group('mergeConsecutiveTurns', () {
    test('merges same-channel fragments with no diarization', () {
      final result = mergeConsecutiveTurns([
        line('we should', 0, 500),
        line('ship on friday', 700, 1000),
      ]);

      expect(result, hasLength(1));
      expect(result.single.text, 'we should ship on friday');
    });

    test('keeps different channels apart', () {
      final result = mergeConsecutiveTurns([
        line('mine', 0, 500, channel: MeetingChannel.near),
        line('theirs', 600, 1000),
      ]);

      expect(result, hasLength(2));
    });

    test('returns a single line unchanged', () {
      final lines = [line('only', 0, 500)];
      expect(mergeConsecutiveTurns(lines), same(lines));
    });
  });
}
