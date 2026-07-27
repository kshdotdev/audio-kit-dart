import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voice_core/voice_core.dart';

/// Accessible start/stop/interrupt control driven by voice_core state.
class VoiceControlButton extends StatelessWidget {
  /// Creates a voice control.
  const VoiceControlButton({
    required this.snapshot,
    required this.onStart,
    required this.onStop,
    required this.onInterrupt,
    this.compact = false,
    super.key,
  });

  /// Current state.
  final VoiceConversationSnapshot snapshot;

  /// Starts a session.
  final FutureOr<void> Function() onStart;

  /// Stops a session.
  final FutureOr<void> Function() onStop;

  /// Interrupts a speaking/thinking turn.
  final FutureOr<void> Function() onInterrupt;

  /// Whether to render an icon-only button.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final action = _actionFor(snapshot);
    final callback = switch (action.kind) {
      _VoiceActionKind.start => onStart,
      _VoiceActionKind.stop => onStop,
      _VoiceActionKind.interrupt => onInterrupt,
      _VoiceActionKind.disabled => null,
    };

    if (compact) {
      return IconButton(
        tooltip: action.label,
        onPressed: callback,
        icon: Icon(action.icon),
      );
    }
    return FilledButton.icon(
      onPressed: callback,
      icon: Icon(action.icon),
      label: Text(action.label),
    );
  }
}

_VoiceAction _actionFor(VoiceConversationSnapshot snapshot) {
  switch (snapshot.sessionState) {
    case VoiceSessionState.idle || VoiceSessionState.failed:
      return const _VoiceAction(
        _VoiceActionKind.start,
        'Start listening',
        Icons.mic,
      );
    case VoiceSessionState.preparing || VoiceSessionState.stopping:
      return const _VoiceAction(
        _VoiceActionKind.disabled,
        'Please wait',
        Icons.hourglass_top,
      );
    case VoiceSessionState.closed:
      return const _VoiceAction(
        _VoiceActionKind.disabled,
        'Voice closed',
        Icons.mic_off,
      );
    case VoiceSessionState.active:
      if (snapshot.turnState == VoiceTurnState.speaking ||
          snapshot.turnState == VoiceTurnState.thinking) {
        return const _VoiceAction(
          _VoiceActionKind.interrupt,
          'Interrupt response',
          Icons.stop_circle_outlined,
        );
      }
      return const _VoiceAction(
        _VoiceActionKind.stop,
        'Stop listening',
        Icons.stop,
      );
  }
}

enum _VoiceActionKind { start, stop, interrupt, disabled }

final class _VoiceAction {
  const _VoiceAction(this.kind, this.label, this.icon);

  final _VoiceActionKind kind;
  final String label;
  final IconData icon;
}
