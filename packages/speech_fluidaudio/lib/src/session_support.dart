import 'dart:async';

import 'package:audio_core/audio_core.dart';

/// Internal lifecycle base shared by FluidAudio source and sink sessions.
abstract base class FluidManagedSession implements AudioSession {
  FluidManagedSession({required this.onClosed})
    : _status = const AudioSessionStatus(
        state: AudioSessionState.prepared,
        timestamp: Duration.zero,
      ) {
    _clock.start();
  }

  /// Removes this session from its provider when resources are closed.
  final void Function(FluidManagedSession session) onClosed;

  final Stopwatch _clock = Stopwatch();
  final StreamController<AudioSessionStatus> _statusController =
      StreamController<AudioSessionStatus>.broadcast(sync: true);
  AudioSessionStatus _status;
  Future<void>? _closeStatusFuture;

  @override
  AudioSessionStatus get status => _status;

  @override
  Stream<AudioSessionStatus> get statuses =>
      Stream<AudioSessionStatus>.multi((controller) {
        controller.add(_status);
        final subscription = _statusController.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = subscription.cancel;
      }, isBroadcast: true);

  /// Whether audio can no longer be written or emitted.
  bool get isTerminal => switch (_status.state) {
    AudioSessionState.finished ||
    AudioSessionState.aborted ||
    AudioSessionState.failed ||
    AudioSessionState.closed => true,
    _ => false,
  };

  /// Emits a lifecycle transition.
  void transition(AudioSessionState state, {AudioFailure? failure}) {
    if (_status.state == AudioSessionState.closed) {
      return;
    }
    if (isTerminal && state != AudioSessionState.closed) {
      return;
    }
    _status = AudioSessionStatus(
      state: state,
      timestamp: _clock.elapsed,
      failure: failure,
    );
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }

  /// Returns a timestamp on this session's monotonic clock.
  Duration get elapsed => _clock.elapsed;

  /// Throws when an operation is issued after a terminal transition.
  void ensureUsable(String operation) {
    if (isTerminal) {
      throw StateError(
        'Cannot $operation a FluidAudio session in '
        '${_status.state.name} state.',
      );
    }
  }

  /// Closes the lifecycle event stream and unregisters this session.
  Future<void> closeLifecycle() => _closeStatusFuture ??= _closeLifecycleOnce();

  Future<void> _closeLifecycleOnce() {
    if (_status.state != AudioSessionState.closed) {
      transition(AudioSessionState.closed);
    }
    if (!_statusController.isClosed) {
      unawaited(_statusController.close());
    }
    onClosed(this);
    return Future<void>.value();
  }
}

/// Maps a provider failure onto the generic audio sink/source failure shape.
AudioFailure fluidAudioFailure(
  String code,
  AudioFailureStage stage,
  String message, {
  bool retryable = false,
  Object? cause,
}) => AudioFailure(
  code: code,
  stage: stage,
  providerId: 'fluidaudio',
  retryable: retryable,
  message: message,
  safeCause: cause?.runtimeType.toString(),
);
