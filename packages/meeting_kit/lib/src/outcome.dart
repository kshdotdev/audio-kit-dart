// The outcome schema and its two parsers are derived from Control Center's
// `meeting_outcome.dart`, MIT (c) 2026 Samuel Alev. See NOTICE.

import 'dart:convert';

/// One action item from a meeting summary.
final class MeetingActionItem {
  /// Creates an action item.
  const MeetingActionItem(this.text, {this.owner});

  /// The action-item text.
  final String text;

  /// Optional owner or assignee.
  final String? owner;

  @override
  bool operator ==(Object other) =>
      other is MeetingActionItem && other.text == text && other.owner == owner;

  @override
  int get hashCode => Object.hash(text, owner);

  @override
  String toString() => owner == null
      ? 'MeetingActionItem($text)'
      : 'MeetingActionItem($text, owner: $owner)';
}

/// The normalized, structured result of a meeting-summary model run.
///
/// A summarizing model returns either a structured payload — when the host
/// enforces [schema] through a tool-call contract — or plain prose. [parse]
/// normalizes both into one struct so downstream persistence never parses a
/// notes body itself, while [MeetingOutcome.fromValidatedJson] is the strict
/// reader for an already-validated payload.
final class MeetingOutcome {
  /// Creates an outcome.
  const MeetingOutcome({
    this.title,
    this.summary,
    this.enhancedNotes,
    this.actionItems = const [],
    this.decisions = const [],
    this.speakerNames = const {},
    this.isStructured = false,
  });

  /// Strictly reads an already-schema-validated payload.
  ///
  /// One canonical key per field and no fallbacks, so a validator bug surfaces
  /// as a missing field rather than silent coercion. Use [parse] for anything
  /// that has not been validated.
  factory MeetingOutcome.fromValidatedJson(Map<String, dynamic> json) {
    return MeetingOutcome(
      isStructured: true,
      title: _str(json['title']),
      summary: _str(json['summary']),
      enhancedNotes: _str(json['enhancedNotes']),
      actionItems: [
        for (final entry in (json['actionItems'] as List? ?? const []))
          if (entry is Map && entry['text'] is String)
            MeetingActionItem(
              (entry['text'] as String).trim(),
              owner: _str(entry['owner']),
            ),
      ],
      decisions: [
        for (final decision in (json['decisions'] as List? ?? const []))
          if (decision is String && decision.trim().isNotEmpty) decision.trim(),
      ],
      speakerNames: _speakerNames(json['speakerNames']),
    );
  }

  /// An outcome carrying nothing recognizable.
  static const MeetingOutcome empty = MeetingOutcome();

  /// The output contract for a meeting-summary model call.
  ///
  /// Hand this to whichever structured-output mechanism the host uses so the
  /// model is told the exact keys, then read the result with
  /// [MeetingOutcome.fromValidatedJson].
  static const Map<String, dynamic> schema = {
    'type': 'object',
    'required': ['enhancedNotes'],
    'properties': {
      'title': {'type': 'string'},
      'summary': {'type': 'string'},
      'enhancedNotes': {'type': 'string'},
      'actionItems': {
        'type': 'array',
        'items': {
          'type': 'object',
          'required': ['text'],
          'properties': {
            'text': {'type': 'string'},
            'owner': {'type': 'string', 'nullable': true},
          },
        },
      },
      'decisions': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'speakerNames': {
        'type': 'object',
        'additionalProperties': {'type': 'string'},
      },
    },
  };

  /// Whether a real structured object was recovered.
  ///
  /// When false the host should update notes only and skip replacing action
  /// items or decisions — a degraded run must not wipe rows a previous run
  /// saved.
  final bool isStructured;

  /// A short content-derived title, when present.
  ///
  /// Apply it only while the meeting's title is not user-customized, so a
  /// generated title never clobbers a chosen one.
  final String? title;

  /// Short executive summary, when present.
  final String? summary;

  /// Clean enhanced notes, when present.
  final String? enhancedNotes;

  /// Action items, in the model's order.
  final List<MeetingActionItem> actionItems;

  /// Decisions, in the model's order.
  final List<String> decisions;

  /// Names inferred from explicit transcript cues, mapping a diarization label
  /// such as `Person 1` to a real name.
  ///
  /// Apply one only to a speaker that has no name yet; a voice-profile match or
  /// a user rename always wins. See [SpeakerNameSource].
  final Map<String, String> speakerNames;

  /// Parses [raw] leniently.
  ///
  /// Accepts a map, a JSON string, a fenced code block, or plain prose — which
  /// is kept verbatim as [enhancedNotes] so a recording is never lost.
  static MeetingOutcome parse(Object? raw) {
    final map = _asMap(raw);
    if (map == null) {
      final text = raw is String ? raw.trim() : '';
      return MeetingOutcome(enhancedNotes: text.isEmpty ? null : text);
    }
    return MeetingOutcome(
      isStructured: true,
      title: _str(map['title'] ?? map['Title']),
      summary: _str(map['summary'] ?? map['Summary']),
      enhancedNotes: _str(
        map['enhancedNotes'] ??
            map['enhanced_notes'] ??
            map['notes'] ??
            map['Notes'],
      ),
      actionItems: _actionItems(
        map['actionItems'] ?? map['action_items'] ?? map['actions'],
      ),
      decisions: _decisions(map['decisions'] ?? map['Decisions']),
      speakerNames: _speakerNames(map['speakerNames'] ?? map['speaker_names']),
    );
  }

  static Map<String, dynamic>? _asMap(Object? raw) {
    if (raw is Map) {
      final map = raw.cast<String, dynamic>();
      // A host may wrap the payload as {result: <inner>}; unwrap a structured
      // inner value so that convention still works.
      if (map.length == 1 && map.containsKey('result')) {
        final inner = _asMap(map['result']);
        if (inner != null) {
          return inner;
        }
      }
      return map;
    }
    if (raw is String) {
      final decoded = _tryDecode(raw);
      if (decoded is Map) {
        return _asMap(decoded);
      }
    }
    return null;
  }

  static Object? _tryDecode(String raw) {
    var source = raw.trim();
    if (source.isEmpty) {
      return null;
    }
    final fence = RegExp(
      r'^```[a-zA-Z]*\s*([\s\S]*?)\s*```$',
    ).firstMatch(source);
    if (fence != null) {
      source = fence.group(1)!.trim();
    }
    if (!source.startsWith('{')) {
      final start = source.indexOf('{');
      final end = source.lastIndexOf('}');
      if (start < 0 || end <= start) {
        return null;
      }
      source = source.substring(start, end + 1);
    }
    try {
      return jsonDecode(source);
    } on FormatException {
      return null;
    }
  }

  static String? _str(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }

  static List<MeetingActionItem> _actionItems(Object? value) {
    if (value is! List) {
      return const [];
    }
    final out = <MeetingActionItem>[];
    for (final entry in value) {
      if (entry is String) {
        final text = entry.trim();
        if (text.isNotEmpty) {
          out.add(MeetingActionItem(text));
        }
      } else if (entry is Map) {
        final map = entry.cast<String, dynamic>();
        final text = _str(
          map['text'] ??
              map['action'] ??
              map['item'] ??
              map['title'] ??
              map['task'] ??
              map['description'],
        );
        if (text != null) {
          out.add(
            MeetingActionItem(
              text,
              owner: _str(map['owner'] ?? map['assignee'] ?? map['who']),
            ),
          );
        }
      }
    }
    return out;
  }

  static List<String> _decisions(Object? value) {
    if (value is! List) {
      return const [];
    }
    final out = <String>[];
    for (final entry in value) {
      if (entry is String) {
        final text = entry.trim();
        if (text.isNotEmpty) {
          out.add(text);
        }
      } else if (entry is Map) {
        final map = entry.cast<String, dynamic>();
        final text = _str(
          map['text'] ?? map['decision'] ?? map['title'] ?? map['description'],
        );
        if (text != null) {
          out.add(text);
        }
      }
    }
    return out;
  }

  /// Reads `speakerNames` defensively, keeping only entries whose key and value
  /// are both non-empty strings so a partial map never injects blank labels.
  static Map<String, String> _speakerNames(Object? value) {
    if (value is! Map) {
      return const {};
    }
    final out = <String, String>{};
    value.forEach((key, name) {
      if (key is String && name is String) {
        final label = key.trim();
        final resolved = name.trim();
        if (label.isNotEmpty && resolved.isNotEmpty) {
          out[label] = resolved;
        }
      }
    });
    return out;
  }
}

/// Where a speaker's display name came from.
///
/// Recorded alongside the name so a host can apply the precedence rule — a user
/// rename outranks a voice-profile match, which outranks anything inferred —
/// and so a later correction can un-apply exactly the right source.
enum SpeakerNameSource {
  /// A positional label produced by diarization, such as `Person 1`.
  diarization,

  /// Seeded from a linked calendar event's invitee list.
  ///
  /// Calendar integration itself is out of scope for this package; the value
  /// exists so hosts can record the provenance when they add one.
  calendarInvitee,

  /// Matched against an enrolled voice profile.
  voiceProfile,

  /// Set explicitly by the user.
  user,
}

/// A speaker's resolved display name together with its provenance.
final class SpeakerName {
  /// Creates a named speaker.
  const SpeakerName({
    required this.label,
    required this.displayName,
    required this.source,
  });

  /// The diarization label this name belongs to, such as `Person 1`.
  final String label;

  /// The resolved display name.
  final String displayName;

  /// Where the name came from.
  final SpeakerNameSource source;

  @override
  bool operator ==(Object other) =>
      other is SpeakerName &&
      other.label == label &&
      other.displayName == displayName &&
      other.source == source;

  @override
  int get hashCode => Object.hash(label, displayName, source);
}
