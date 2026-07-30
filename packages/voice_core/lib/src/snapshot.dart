import 'backend.dart';
import 'duplex.dart';
import 'failure.dart';

/// Lifecycle of the complete voice session.
enum VoiceSessionState { idle, preparing, active, stopping, failed, closed }

/// Lifecycle of the current conversational turn.
enum VoiceTurnState { idle, listening, thinking, speaking, interrupted }

/// Immutable state consumed by UI layers.
final class VoiceConversationSnapshot {
  const VoiceConversationSnapshot({
    required this.sessionState,
    required this.turnState,
    required this.generationId,
    this.duplexMode = VoiceDuplexMode.halfDuplex,
    this.interimTranscript = '',
    this.finalTranscript = '',
    this.responseText = '',
    this.lastToolCall,
    this.failure,
  });

  /// Overall session lifecycle.
  final VoiceSessionState sessionState;

  /// Current turn lifecycle.
  final VoiceTurnState turnState;

  /// Current generation. Events from lower generations are stale.
  final int generationId;

  /// Duplex mode actually in effect for this conversation.
  ///
  /// Constant for the controller's lifetime and resolved before the session
  /// starts, so a listener that requested full duplex and sees
  /// [VoiceDuplexMode.halfDuplex] here is looking at a degradation — normally
  /// because no echo canceller was available. `VoiceDuplexConfig.isDegraded`
  /// says so directly.
  final VoiceDuplexMode duplexMode;

  /// Replaceable user recognition hypothesis.
  final String interimTranscript;

  /// Most recently committed user transcript.
  final String finalTranscript;

  /// Accumulated response narrative for the current generation.
  final String responseText;

  /// Most recent structured tool event.
  final VoiceToolCall? lastToolCall;

  /// Safe terminal or recoverable failure.
  final VoiceFailure? failure;

  /// Initial inactive state.
  static const VoiceConversationSnapshot initial = VoiceConversationSnapshot(
    sessionState: VoiceSessionState.idle,
    turnState: VoiceTurnState.idle,
    generationId: 0,
  );

  /// Creates a modified state.
  VoiceConversationSnapshot copyWith({
    VoiceSessionState? sessionState,
    VoiceTurnState? turnState,
    int? generationId,
    VoiceDuplexMode? duplexMode,
    String? interimTranscript,
    String? finalTranscript,
    String? responseText,
    VoiceToolCall? lastToolCall,
    bool clearLastToolCall = false,
    VoiceFailure? failure,
    bool clearFailure = false,
  }) => VoiceConversationSnapshot(
    sessionState: sessionState ?? this.sessionState,
    turnState: turnState ?? this.turnState,
    generationId: generationId ?? this.generationId,
    duplexMode: duplexMode ?? this.duplexMode,
    interimTranscript: interimTranscript ?? this.interimTranscript,
    finalTranscript: finalTranscript ?? this.finalTranscript,
    responseText: responseText ?? this.responseText,
    lastToolCall: clearLastToolCall
        ? null
        : (lastToolCall ?? this.lastToolCall),
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}
