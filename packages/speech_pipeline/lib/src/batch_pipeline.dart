import 'dart:async';

import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'hallucination_filters.dart';
import 'transcript_segment.dart';
import 'window_cutter.dart';

// The in-order decode discipline and the per-stream generation guard follow
// Control Center's `meeting_transcription_service.dart`
// (MIT © 2026 Samuel Alev). See NOTICE.

/// Turns a continuous capture stream plus a batch recognizer into a live
/// transcript.
///
/// Streaming providers do not need this: they already emit incremental results.
/// This is the adapter that makes a batch-only provider — the common case off
/// Apple platforms — usable for live transcription.
///
/// Windows decode strictly in order. A decode is asynchronous and may outlast
/// several inbound frames, so windows queue while one is in flight rather than
/// pausing the source, which realtime capture streams reject.
final class BatchTranscriptionPipeline {
  /// Creates a pipeline over [provider].
  BatchTranscriptionPipeline({
    required this.provider,
    AudioWindowCutter? cutter,
    this.options,
    this.filterHallucinations = true,
  }) : cutter = cutter ?? AudioWindowCutter();

  /// Recognizer each cut window is decoded with.
  final BatchSpeechToTextProvider provider;

  /// Window cut policy and speech gate.
  final AudioWindowCutter cutter;

  /// Recognition options forwarded to [provider] on every window.
  final SpeechRecognitionOptions? options;

  /// Whether decoded text is passed through the hallucination filters.
  final bool filterHallucinations;

  /// Transcribes [frames], emitting one segment per decoded window.
  ///
  /// Windows containing no speech never reach the provider. Decoded text that
  /// the hallucination filters reject is dropped unless the pipeline was built
  /// with `filterHallucinations: false`. The returned stream closes once
  /// [frames] closes and the final window has decoded.
  Stream<TranscriptSegment> transcribe(Stream<AudioFrame> frames) {
    final controller = StreamController<TranscriptSegment>();
    // Generation guard: a window decodes asynchronously while the stream may be
    // cancelled or replaced. When that happens this flips false and in-flight
    // results are discarded instead of being emitted into a dead stream.
    var streamLive = true;
    // Serialises decodes so windows are emitted in capture order.
    var decodeChain = Future<void>.value();
    var windowsInFlight = 0;
    var sourceDone = false;

    void maybeClose() {
      if (sourceDone && windowsInFlight == 0 && !controller.isClosed) {
        unawaited(controller.close());
      }
    }

    Future<void> decode(AudioWindow window) async {
      if (!streamLive) {
        return;
      }
      try {
        final result = await provider.transcribe(
          BatchRecognitionRequest(audio: window.toSource(), options: options),
        );
        if (!streamLive || controller.isClosed) {
          return; // Cancelled while decoding — discard the stale result.
        }
        final text = result.text.trim();
        if (text.isEmpty) {
          return;
        }
        if (filterHallucinations && isHallucinatedTranscript(text)) {
          return;
        }
        controller.add(
          TranscriptSegment(
            trackId: window.trackId,
            text: text,
            start: window.start,
            end: window.end,
          ),
        );
      } catch (error, stackTrace) {
        if (streamLive && !controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      }
    }

    late StreamSubscription<AudioWindow> subscription;
    subscription = cutter
        .cut(frames)
        .listen(
          (window) {
            windowsInFlight++;
            decodeChain = decodeChain.then((_) => decode(window)).whenComplete(
              () {
                windowsInFlight--;
                maybeClose();
              },
            );
          },
          onError: controller.addError,
          onDone: () {
            sourceDone = true;
            maybeClose();
          },
          cancelOnError: false,
        );

    controller.onCancel = () async {
      streamLive = false;
      await subscription.cancel();
    };
    return controller.stream;
  }
}
