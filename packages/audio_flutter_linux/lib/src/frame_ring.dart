import 'dart:collection';

import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// Outcome of offering a frame to a bounded ring.
enum FrameRingAdmission {
  /// The frame is queued for the next pull.
  accepted,

  /// The frame displaced the oldest queued frame.
  displacedOldest,

  /// The frame itself was discarded.
  discarded,

  /// The ring is full under a fail-fast policy; the session must fail.
  overflowed,
}

/// Bounded queue between the capture producer and [readCaptureFrames]-style
/// pulls, mirroring the bounded mailbox the Darwin implementation keeps in
/// native code.
///
/// Drop accounting follows the platform contract: `sequence` and `sampleOffset`
/// are assigned by the producer and therefore keep advancing across drops, and
/// the frame delivered after a gap reports how many frames vanished before it.
final class FrameRing {
  FrameRing({required this.capacity, required this.policy})
    : assert(capacity > 0);

  final int capacity;
  final PlatformCaptureOverflowPolicy policy;

  final Queue<PlatformAudioFrame> _frames = Queue<PlatformAudioFrame>();

  /// Frames evicted from the head, owed to whichever frame is read next.
  int _dropsBeforeHead = 0;

  /// Frames refused at the tail, owed to the next frame actually queued.
  int _dropsBeforeNextAdd = 0;

  bool get isEmpty => _frames.isEmpty;

  int get length => _frames.length;

  FrameRingAdmission add(PlatformAudioFrame frame) {
    if (_frames.length < capacity) {
      _frames.addLast(_withPendingTailDrops(frame));
      return FrameRingAdmission.accepted;
    }

    switch (policy) {
      case PlatformCaptureOverflowPolicy.dropOldest:
        _frames.removeFirst();
        _dropsBeforeHead++;
        _frames.addLast(_withPendingTailDrops(frame));
        return FrameRingAdmission.displacedOldest;
      case PlatformCaptureOverflowPolicy.dropNewest:
        _dropsBeforeNextAdd++;
        return FrameRingAdmission.discarded;
      case PlatformCaptureOverflowPolicy.failCapture:
        return FrameRingAdmission.overflowed;
    }
  }

  /// Removes and returns at most [maxFrames] frames, oldest first.
  List<PlatformAudioFrame> take(int maxFrames) {
    if (maxFrames <= 0 || _frames.isEmpty) {
      return const <PlatformAudioFrame>[];
    }
    final int count = maxFrames < _frames.length ? maxFrames : _frames.length;
    final List<PlatformAudioFrame> taken = <PlatformAudioFrame>[];
    for (var index = 0; index < count; index++) {
      var frame = _frames.removeFirst();
      if (index == 0 && _dropsBeforeHead > 0) {
        frame = _copyWithDrops(
          frame,
          frame.droppedFramesBefore + _dropsBeforeHead,
        );
        _dropsBeforeHead = 0;
      }
      taken.add(frame);
    }
    return taken;
  }

  void clear() {
    _frames.clear();
    _dropsBeforeHead = 0;
    _dropsBeforeNextAdd = 0;
  }

  PlatformAudioFrame _withPendingTailDrops(PlatformAudioFrame frame) {
    if (_dropsBeforeNextAdd == 0) {
      return frame;
    }
    final PlatformAudioFrame adjusted = _copyWithDrops(
      frame,
      frame.droppedFramesBefore + _dropsBeforeNextAdd,
    );
    _dropsBeforeNextAdd = 0;
    return adjusted;
  }

  static PlatformAudioFrame _copyWithDrops(
    PlatformAudioFrame frame,
    int droppedFramesBefore,
  ) => PlatformAudioFrame(
    sessionId: frame.sessionId,
    sequence: frame.sequence,
    sampleOffset: frame.sampleOffset,
    timestamp: frame.timestamp,
    samples: frame.samples,
    droppedFramesBefore: droppedFramesBefore,
  );
}
