import 'package:flutter/material.dart';
import 'package:voice_core/voice_core.dart';

/// Displays committed/interim user text and accumulated assistant narrative.
class VoiceTranscriptView extends StatelessWidget {
  /// Creates a transcript view.
  const VoiceTranscriptView({
    required this.snapshot,
    this.userLabel = 'You',
    this.assistantLabel = 'Assistant',
    this.emptyMessage = 'Start speaking to begin.',
    super.key,
  });

  /// State to display.
  final VoiceConversationSnapshot snapshot;

  /// Label for recognized user text.
  final String userLabel;

  /// Label for backend narrative.
  final String assistantLabel;

  /// Message shown before any transcript exists.
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final userText = snapshot.interimTranscript.isNotEmpty
        ? snapshot.interimTranscript
        : snapshot.finalTranscript;
    if (userText.isEmpty && snapshot.responseText.isEmpty) {
      return Text(
        emptyMessage,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.outline,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (userText.isNotEmpty)
          _TranscriptSection(
            label: userLabel,
            text: userText,
            isInterim: snapshot.interimTranscript.isNotEmpty,
          ),
        if (userText.isNotEmpty && snapshot.responseText.isNotEmpty)
          const SizedBox(height: 12),
        if (snapshot.responseText.isNotEmpty)
          _TranscriptSection(
            label: assistantLabel,
            text: snapshot.responseText,
          ),
        if (snapshot.failure case final failure?)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              failure.message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}

class _TranscriptSection extends StatelessWidget {
  const _TranscriptSection({
    required this.label,
    required this.text,
    this.isInterim = false,
  });

  final String label;
  final String text;
  final bool isInterim;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label: $text',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 2),
        Text(
          text,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            fontStyle: isInterim ? FontStyle.italic : null,
            color: isInterim
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : null,
          ),
        ),
      ],
    ),
  );
}
