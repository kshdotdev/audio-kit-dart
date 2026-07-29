import 'package:audio_aec/audio_aec.dart';
import 'package:audio_core/audio_core.dart';
import 'package:audio_kit_graph/audio_kit_graph.dart';
import 'package:voice_core/voice_core.dart';

import 'graph_voice_speech_output.dart';
import 'voice_far_end_tap.dart';

/// What happened when a full-duplex session tried to build its echo canceller.
enum VoiceEchoCancellationOutcome {
  /// An engine was created; the microphone reaching recognition is cancelled.
  active,

  /// No engine could be created, so the session runs half duplex.
  ///
  /// The microphone handed back is the raw one, untouched — the degraded path
  /// is byte-for-byte the ordinary half-duplex path, not a passthrough wrapper
  /// around it.
  unavailableFellBackToHalfDuplex,

  /// No engine could be created and the caller opted into the echo risk.
  ///
  /// Recognition stays live through playback against an uncancelled
  /// microphone. Expect the recognizer to hear the assistant.
  unavailableEchoRiskAccepted,
}

/// Builds the acoustic-echo-cancellation composition for an opt-in full-duplex
/// voice session.
///
/// ## Why this lives here and not in `voice_core`
///
/// `voice_core` is pure orchestration: pure Dart, no graph, no native code, and
/// deliberately no dependency on `audio_aec` — which ships no binary and whose
/// distribution story is still open. Pushing that dependency down would make
/// every pure-Dart consumer of the conversation state machine inherit a native
/// resolution problem in order to use a mode most of them will not enable.
///
/// So the split is: `voice_core` learns the *policy* — a resolved
/// [VoiceDuplexConfig] telling it whether to gate recognition and what counts
/// as barge-in — and this layer owns the *mechanism*, because the mechanism is
/// entirely `audio_core` sources and `audio_kit_graph` fan-out, which
/// `voice_flutter` already depends on. The controller never learns that an echo
/// canceller exists; it is simply told the microphone is clean.
///
/// ## What it composes
///
/// ```text
///   raw microphone ─┐
///                   ├─► AecMicFilter ──► GraphVoiceInput ──► STT + VAD
///   VoiceFarEndTap ─┘         (near/far)
///          ▲
///          └── reference route ◄─┬── AudioRouter ◄── synthesized source
///              device playback ◄─┘
/// ```
///
/// The same synthesized frames reach the speakers and the canceller, from one
/// router dispatch, in one order.
///
/// ## Degradation
///
/// [AecProcessor.create] throws [AecUnavailable] when no native library can be
/// resolved. That is a broken install, not a runtime condition, so it is caught
/// exactly once — here — and turned into a resolved policy rather than being
/// allowed to fail a session that could still work. The default is
/// [VoiceEchoCancellationFallback.halfDuplex]: an uncancelled microphone held
/// open through playback is strictly worse than the gated baseline, because the
/// recognizer transcribes the assistant and the conversation talks to itself.
/// Full duplex without cancellation is available, but only by explicitly
/// passing [VoiceEchoCancellationFallback.acceptEchoRisk].
///
/// ## Single-start
///
/// One composition drives one capture session. [AecMicFilter] binds a single
/// stateful native engine and rejects a second `prepare`, so a `GraphVoiceInput`
/// over [microphone] cannot be restarted after `stop()`. Compose again — which
/// creates a fresh engine — to start a new session.
///
/// ## Usage
///
/// ```dart
/// final setup = VoiceFullDuplexSetup.compose(
///   microphone: rawMicrophoneSource,
///   captureFormat: AudioFormat(sampleRate: 16000, channels: 1),
/// );
/// final controller = VoiceConversationController(
///   input: GraphVoiceInput(
///     source: setup.microphone,
///     streamingSpeechToText: stt,
///     voiceActivityDetection: vad,
///   ),
///   backend: backend,
///   synthesizer: tts,
///   output: GraphVoiceSpeechOutput(
///     playbackSink: deviceSink,
///     extraRoutes: setup.outputRoutes,
///   ),
///   duplex: setup.duplex,
/// );
/// ```
final class VoiceFullDuplexSetup {
  const VoiceFullDuplexSetup._({
    required this.microphone,
    required this.farEndTap,
    required this.duplex,
    required this.echoCancellation,
    required this.unavailable,
  });

  /// Composes an echo-cancelled microphone and its playback reference tap.
  ///
  /// [microphone] is the raw capture source, which must already be dry: the
  /// microphone-DSP invariant is capture dry and cancel in software, because
  /// enabling platform echo cancellation or AGC on the capture device changes
  /// the signal out from under the reference.
  ///
  /// [captureFormat] must be [microphone]'s format and is what the reference is
  /// held to. Echo cancellation is mono only.
  ///
  /// [engine] builds the canceller and defaults to [AecProcessor.create] at
  /// [captureFormat]'s rate. Supplying it is how a test — or a platform with its
  /// own canceller — swaps the native edge out. It may throw [AecUnavailable];
  /// anything else it throws is a real defect and propagates.
  ///
  /// [fallback] and [interruptAfterSustainedSpeech] are forwarded to
  /// [VoiceDuplexConfig.fullDuplex]; see it for what barge-in means once voice
  /// activity alone no longer interrupts.
  ///
  /// [log] receives the canceller's calibration and metrics lines.
  factory VoiceFullDuplexSetup.compose({
    required AudioSource microphone,
    required AudioFormat captureFormat,
    AecEngine Function()? engine,
    VoiceEchoCancellationFallback fallback =
        VoiceEchoCancellationFallback.halfDuplex,
    Duration? interruptAfterSustainedSpeech,
    AudioRouteOptions? referenceRouteOptions,
    String referenceRouteId = 'voice-aec-reference',
    void Function(String message)? log,
  }) {
    if (captureFormat.channels != 1) {
      throw ArgumentError.value(
        captureFormat.channels,
        'captureFormat.channels',
        'Echo cancellation is mono only. Downmix before the conversation.',
      );
    }

    final AecEngine Function() build =
        engine ??
        () => AecProcessor.create(sampleRate: captureFormat.sampleRate);
    final AecEngine created;
    try {
      created = build();
    } on AecUnavailable catch (unavailable) {
      final VoiceDuplexConfig degraded = VoiceDuplexConfig.fullDuplex(
        echoCancelled: false,
        fallback: fallback,
        interruptAfterSustainedSpeech: interruptAfterSustainedSpeech,
      );
      log?.call(
        'Echo cancellation unavailable: ${unavailable.message} '
        '-> running ${degraded.mode.name}.',
      );
      return VoiceFullDuplexSetup._(
        // Deliberately the raw source. With no engine there is nothing to
        // reference and nothing to subtract, so wrapping it would add a layer
        // and a failure surface for an identity transform.
        microphone: microphone,
        farEndTap: null,
        duplex: degraded,
        echoCancellation: degraded.mode == VoiceDuplexMode.fullDuplex
            ? VoiceEchoCancellationOutcome.unavailableEchoRiskAccepted
            : VoiceEchoCancellationOutcome.unavailableFellBackToHalfDuplex,
        unavailable: unavailable,
      );
    }

    final VoiceFarEndTap tap = VoiceFarEndTap(
      format: captureFormat,
      routeId: referenceRouteId,
      routeOptions: referenceRouteOptions,
    );
    return VoiceFullDuplexSetup._(
      microphone: AecMicFilter(
        near: microphone,
        far: tap,
        processor: created,
        log: log,
      ),
      farEndTap: tap,
      duplex: VoiceDuplexConfig.fullDuplex(
        fallback: fallback,
        interruptAfterSustainedSpeech: interruptAfterSustainedSpeech,
      ),
      echoCancellation: VoiceEchoCancellationOutcome.active,
      unavailable: null,
    );
  }

  /// Capture source to hand to `GraphVoiceInput`.
  ///
  /// The echo-cancelled composition when one could be built, otherwise the raw
  /// microphone passed in.
  final AudioSource microphone;

  /// Playback reference tap, or `null` when there is no canceller to feed.
  final VoiceFarEndTap? farEndTap;

  /// Resolved policy to hand to `VoiceConversationController`.
  final VoiceDuplexConfig duplex;

  /// What happened when the canceller was built.
  final VoiceEchoCancellationOutcome echoCancellation;

  /// The structured unavailability, when there is no canceller.
  ///
  /// Carries every library path the loader tried, which is what makes a missing
  /// native library diagnosable rather than merely absent.
  final AecUnavailable? unavailable;

  /// Whether the microphone reaching recognition is echo-cancelled.
  bool get isEchoCancelled =>
      echoCancellation == VoiceEchoCancellationOutcome.active;

  /// Route builder to hand to `GraphVoiceSpeechOutput.extraRoutes`.
  ///
  /// Yields the reference route, or nothing when there is no canceller. An
  /// application with its own output branches should concatenate:
  ///
  /// ```dart
  /// extraRoutes: (format) async => <VoiceSpeechOutputRoute>[
  ///   ...await setup.outputRoutes(format),
  ///   ...myRoutes(format),
  /// ],
  /// ```
  Iterable<VoiceSpeechOutputRoute> outputRoutes(AudioFormat format) {
    final VoiceFarEndTap? tap = farEndTap;
    return tap == null
        ? const <VoiceSpeechOutputRoute>[]
        : <VoiceSpeechOutputRoute>[tap.route()];
  }
}
