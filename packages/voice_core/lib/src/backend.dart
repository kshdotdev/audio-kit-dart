import 'package:audio_core/audio_core.dart';

import 'failure.dart';

/// Typed application context sent with a backend request.
abstract interface class VoiceConversationContext {}

/// Context for backends that require no application-specific values.
final class EmptyVoiceConversationContext implements VoiceConversationContext {
  const EmptyVoiceConversationContext();
}

/// A cancellable, generation-scoped backend request.
final class VoiceBackendRequest {
  const VoiceBackendRequest({
    required this.transcript,
    required this.context,
    required this.generationId,
    required this.cancellationToken,
  });

  /// Committed user transcript.
  final String transcript;

  /// Typed application context.
  final VoiceConversationContext context;

  /// Monotonically increasing turn generation.
  final int generationId;

  /// Cooperative cancellation signal.
  final AudioCancellationToken cancellationToken;
}

/// Marker for typed tool payloads.
abstract interface class VoiceToolPayload {}

/// Lifecycle phase of a backend tool call.
enum VoiceToolPhase { started, progress, completed, failed }

/// Structured backend tool event.
final class VoiceToolCall {
  const VoiceToolCall({
    required this.callId,
    required this.name,
    required this.phase,
    this.statusText,
    this.payload,
  });

  /// Stable call ID within one backend response.
  final String callId;

  /// Stable tool name.
  final String name;

  /// Current tool lifecycle phase.
  final VoiceToolPhase phase;

  /// Optional user-safe progress text.
  final String? statusText;

  /// Typed payload implemented by the application or adapter.
  final VoiceToolPayload? payload;
}

/// Base type for a typed streaming backend response.
sealed class VoiceBackendEvent {
  const VoiceBackendEvent();
}

/// User-safe backend progress.
final class VoiceBackendProgress extends VoiceBackendEvent {
  const VoiceBackendProgress(this.message);

  /// Progress message.
  final String message;
}

/// Marks the beginning of narrative response text.
final class VoiceNarrativeStarted extends VoiceBackendEvent {
  const VoiceNarrativeStarted();
}

/// Incremental narrative text.
final class VoiceNarrativeDelta extends VoiceBackendEvent {
  const VoiceNarrativeDelta(this.text);

  /// Text fragment, which may split words or punctuation.
  final String text;
}

/// Marks the end of narrative response text.
final class VoiceNarrativeEnded extends VoiceBackendEvent {
  const VoiceNarrativeEnded();
}

/// Structured tool lifecycle update.
final class VoiceBackendTool extends VoiceBackendEvent {
  const VoiceBackendTool(this.call);

  /// Tool update.
  final VoiceToolCall call;
}

/// Explicit successful completion marker.
final class VoiceBackendCompleted extends VoiceBackendEvent {
  const VoiceBackendCompleted();
}

/// Explicit backend failure marker.
final class VoiceBackendFailed extends VoiceBackendEvent {
  const VoiceBackendFailed(this.failure);

  /// Safe backend failure.
  final VoiceFailure failure;
}

/// Application backend that streams generation-scoped responses.
abstract interface class VoiceBackend {
  /// Starts a cold response stream.
  Stream<VoiceBackendEvent> respond(VoiceBackendRequest request);

  /// Releases backend resources. Implementations must be idempotent.
  Future<void> close();
}
