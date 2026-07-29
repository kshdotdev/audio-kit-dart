// Ported from Control Center's meeting_outcome_test.dart,
// MIT (c) 2026 Samuel Alev. See NOTICE.

import 'dart:convert';

import 'package:meeting_kit/meeting_kit.dart';
import 'package:test/test.dart';

void main() {
  group('MeetingOutcome.parse', () {
    test('reads a structured map', () {
      final outcome = MeetingOutcome.parse({
        'title': 'Weekly sync',
        'summary': 'We shipped it.',
        'enhancedNotes': '# Notes',
        'actionItems': [
          {'text': 'Write the migration', 'owner': 'Kauan'},
        ],
        'decisions': ['Ship on Friday'],
        'speakerNames': {'Person 1': 'Kauan'},
      });

      expect(outcome.isStructured, isTrue);
      expect(outcome.title, 'Weekly sync');
      expect(outcome.summary, 'We shipped it.');
      expect(outcome.enhancedNotes, '# Notes');
      expect(outcome.actionItems, [
        const MeetingActionItem('Write the migration', owner: 'Kauan'),
      ]);
      expect(outcome.decisions, ['Ship on Friday']);
      expect(outcome.speakerNames, {'Person 1': 'Kauan'});
    });

    test('reads a JSON string', () {
      final outcome = MeetingOutcome.parse(
        jsonEncode({
          'enhancedNotes': 'Body',
          'decisions': ['Go'],
        }),
      );

      expect(outcome.isStructured, isTrue);
      expect(outcome.enhancedNotes, 'Body');
      expect(outcome.decisions, ['Go']);
    });

    test('reads a fenced JSON block', () {
      final outcome = MeetingOutcome.parse(
        '```json\n{"enhancedNotes": "Body"}\n```',
      );

      expect(outcome.isStructured, isTrue);
      expect(outcome.enhancedNotes, 'Body');
    });

    test('unwraps a result envelope', () {
      final outcome = MeetingOutcome.parse({
        'result': {'enhancedNotes': 'Body'},
      });

      expect(outcome.isStructured, isTrue);
      expect(outcome.enhancedNotes, 'Body');
    });

    test('keeps plain prose verbatim so nothing is lost', () {
      final outcome = MeetingOutcome.parse('Just some notes.');

      expect(outcome.isStructured, isFalse);
      expect(outcome.enhancedNotes, 'Just some notes.');
      expect(outcome.actionItems, isEmpty);
    });

    test('treats empty and null input as nothing recognizable', () {
      expect(MeetingOutcome.parse('').enhancedNotes, isNull);
      expect(MeetingOutcome.parse(null).enhancedNotes, isNull);
      expect(MeetingOutcome.parse(null).isStructured, isFalse);
    });

    test('accepts alternate key spellings', () {
      final outcome = MeetingOutcome.parse({
        'Title': 'T',
        'enhanced_notes': 'N',
        'action_items': ['Do it'],
        'speaker_names': {'Person 1': 'Ada'},
      });

      expect(outcome.title, 'T');
      expect(outcome.enhancedNotes, 'N');
      expect(outcome.actionItems, [const MeetingActionItem('Do it')]);
      expect(outcome.speakerNames, {'Person 1': 'Ada'});
    });

    test('accepts alternate action-item and decision shapes', () {
      final outcome = MeetingOutcome.parse({
        'actionItems': [
          'Bare string',
          {'task': 'Named task', 'assignee': 'Ada'},
          {'nothing': 'useful'},
        ],
        'decisions': [
          {'decision': 'Adopt it'},
          '  ',
        ],
      });

      expect(outcome.actionItems, [
        const MeetingActionItem('Bare string'),
        const MeetingActionItem('Named task', owner: 'Ada'),
      ]);
      expect(outcome.decisions, ['Adopt it']);
    });

    test('drops blank labels and names from the speaker map', () {
      final outcome = MeetingOutcome.parse({
        'speakerNames': {'Person 1': 'Ada', '': 'Nobody', 'Person 2': '  '},
      });

      expect(outcome.speakerNames, {'Person 1': 'Ada'});
    });

    test('ignores non-list collections', () {
      final outcome = MeetingOutcome.parse({
        'actionItems': 'not a list',
        'decisions': 42,
        'speakerNames': 'nope',
      });

      expect(outcome.actionItems, isEmpty);
      expect(outcome.decisions, isEmpty);
      expect(outcome.speakerNames, isEmpty);
    });
  });

  group('MeetingOutcome.fromValidatedJson', () {
    test('reads canonical keys only', () {
      final outcome = MeetingOutcome.fromValidatedJson({
        'title': 'T',
        'summary': 'S',
        'enhancedNotes': 'N',
        'actionItems': [
          {'text': 'Do it', 'owner': 'Ada'},
        ],
        'decisions': ['Ship'],
        'speakerNames': {'Person 1': 'Ada'},
      });

      expect(outcome.isStructured, isTrue);
      expect(outcome.title, 'T');
      expect(outcome.actionItems.single.owner, 'Ada');
      expect(outcome.decisions, ['Ship']);
    });

    test('does not fall back to alternate spellings', () {
      final outcome = MeetingOutcome.fromValidatedJson({
        'enhanced_notes': 'N',
        'action_items': ['Do it'],
      });

      expect(outcome.enhancedNotes, isNull);
      expect(outcome.actionItems, isEmpty);
    });

    test('skips action items without text', () {
      final outcome = MeetingOutcome.fromValidatedJson({
        'actionItems': [
          {'owner': 'Ada'},
          {'text': 'Real'},
        ],
      });

      expect(outcome.actionItems, [const MeetingActionItem('Real')]);
    });

    test('tolerates missing collections', () {
      final outcome = MeetingOutcome.fromValidatedJson({'enhancedNotes': 'N'});

      expect(outcome.actionItems, isEmpty);
      expect(outcome.decisions, isEmpty);
      expect(outcome.speakerNames, isEmpty);
    });
  });

  group('MeetingOutcome.schema', () {
    test('requires enhanced notes and describes every field', () {
      expect(MeetingOutcome.schema['required'], ['enhancedNotes']);

      final properties =
          MeetingOutcome.schema['properties']! as Map<String, dynamic>;
      expect(
        properties.keys,
        containsAll([
          'title',
          'summary',
          'enhancedNotes',
          'actionItems',
          'decisions',
          'speakerNames',
        ]),
      );

      final actionItems = properties['actionItems']! as Map<String, dynamic>;
      final items = actionItems['items']! as Map<String, dynamic>;
      expect(items['required'], ['text']);
    });

    test('is JSON-encodable so it can be sent to a model', () {
      expect(() => jsonEncode(MeetingOutcome.schema), returnsNormally);
    });
  });

  group('empty and equality', () {
    test('the empty outcome carries nothing', () {
      expect(MeetingOutcome.empty.isStructured, isFalse);
      expect(MeetingOutcome.empty.enhancedNotes, isNull);
      expect(MeetingOutcome.empty.actionItems, isEmpty);
    });

    test('action items compare by value', () {
      expect(
        const MeetingActionItem('a', owner: 'b'),
        const MeetingActionItem('a', owner: 'b'),
      );
      expect(
        const MeetingActionItem('a'),
        isNot(const MeetingActionItem('a', owner: 'b')),
      );
    });

    test('speaker names carry their provenance', () {
      const name = SpeakerName(
        label: 'Person 1',
        displayName: 'Ada',
        source: SpeakerNameSource.voiceProfile,
      );

      expect(name.source, SpeakerNameSource.voiceProfile);
      expect(
        name,
        const SpeakerName(
          label: 'Person 1',
          displayName: 'Ada',
          source: SpeakerNameSource.voiceProfile,
        ),
      );
      expect(
        name,
        isNot(
          const SpeakerName(
            label: 'Person 1',
            displayName: 'Ada',
            source: SpeakerNameSource.user,
          ),
        ),
      );
    });
  });
}
