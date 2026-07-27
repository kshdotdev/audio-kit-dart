import 'package:flutter/material.dart';
import 'package:voice_core/voice_core.dart';

/// Accessible visual label for separate session and turn states.
class VoiceStatusIndicator extends StatelessWidget {
  /// Creates a status indicator.
  const VoiceStatusIndicator({
    required this.snapshot,
    this.compact = false,
    super.key,
  });

  /// State to render.
  final VoiceConversationSnapshot snapshot;

  /// Whether to omit the text label.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final presentation = _presentation(snapshot, Theme.of(context).colorScheme);
    return Semantics(
      label: 'Voice status: ${presentation.label}',
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            presentation.icon,
            color: presentation.color,
            size: compact ? 18 : 20,
          ),
          if (!compact) ...[const SizedBox(width: 8), Text(presentation.label)],
        ],
      ),
    );
  }
}

_VoiceStatusPresentation _presentation(
  VoiceConversationSnapshot snapshot,
  ColorScheme colors,
) {
  switch (snapshot.sessionState) {
    case VoiceSessionState.idle:
      return _VoiceStatusPresentation('Idle', Icons.mic_none, colors.outline);
    case VoiceSessionState.preparing:
      return _VoiceStatusPresentation(
        'Preparing',
        Icons.hourglass_top,
        colors.tertiary,
      );
    case VoiceSessionState.stopping:
      return _VoiceStatusPresentation(
        'Stopping',
        Icons.hourglass_bottom,
        colors.tertiary,
      );
    case VoiceSessionState.failed:
      return _VoiceStatusPresentation(
        'Voice failed',
        Icons.error_outline,
        colors.error,
      );
    case VoiceSessionState.closed:
      return _VoiceStatusPresentation('Closed', Icons.mic_off, colors.outline);
    case VoiceSessionState.active:
      break;
  }

  return switch (snapshot.turnState) {
    VoiceTurnState.idle || VoiceTurnState.listening => _VoiceStatusPresentation(
      'Listening',
      Icons.hearing,
      colors.primary,
    ),
    VoiceTurnState.thinking => _VoiceStatusPresentation(
      'Thinking',
      Icons.psychology_outlined,
      colors.tertiary,
    ),
    VoiceTurnState.speaking => _VoiceStatusPresentation(
      'Speaking',
      Icons.graphic_eq,
      colors.secondary,
    ),
    VoiceTurnState.interrupted => _VoiceStatusPresentation(
      'Interrupted',
      Icons.front_hand_outlined,
      colors.error,
    ),
  };
}

final class _VoiceStatusPresentation {
  const _VoiceStatusPresentation(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}
