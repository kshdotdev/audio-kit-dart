/// How the microphone is treated while synthesized speech is playing.
///
/// Half duplex is not a simplification, it is the only safe mode without
/// acoustic echo cancellation: with the microphone open during playback and
/// nothing removing the speaker bleed, recognition transcribes the assistant's
/// own output and the conversation talks to itself. Echo cancellation is the
/// precondition for [fullDuplex], not an optimization of it.
enum VoiceDuplexMode {
  /// Recognition is gated off for the duration of playback, and voice activity
  /// alone interrupts the turn.
  ///
  /// Capture and voice-activity detection stay live throughout so speech can
  /// still interrupt; only the recognition session is torn down and replaced.
  /// The cost is that the beginning of an interrupting utterance is lost, since
  /// nothing was transcribing when the user started talking.
  halfDuplex,

  /// Recognition stays live through playback against an echo-cancelled
  /// microphone, and voice activity alone does not interrupt the turn.
  ///
  /// This is what full duplex buys: the user can talk over the assistant
  /// without losing the onset of the utterance, because the recognizer never
  /// stopped listening. See [VoiceDuplexConfig] for what counts as barge-in
  /// once voice activity no longer does.
  fullDuplex,
}

/// What to do when [VoiceDuplexMode.fullDuplex] was requested but no echo
/// canceller could be built.
enum VoiceEchoCancellationFallback {
  /// Degrade to [VoiceDuplexMode.halfDuplex].
  ///
  /// The default, and the honest one: an uncancelled microphone held open
  /// through playback is strictly worse than the gated baseline, because the
  /// recognizer hears the assistant. Half duplex is never worse than no AEC.
  halfDuplex,

  /// Run full duplex anyway, against an uncancelled microphone.
  ///
  /// Only meaningful when the echo path is known to be negligible — a headset,
  /// or a platform whose driver already cancels — and the caller would rather
  /// keep the onset of interrupting speech than avoid self-transcription. This
  /// is an explicit acceptance of echo risk, which is why it is never a
  /// default.
  acceptEchoRisk,
}

/// Resolved duplex policy for one voice conversation.
///
/// The policy is resolved once, at construction, from what the application
/// asked for and whether echo cancellation actually materialized. [mode] is
/// therefore always the mode genuinely in effect and [isDegraded] reports
/// whether that differs from [requestedMode].
///
/// Resolution is deliberately pure. `voice_core` never touches an echo
/// canceller and carries no dependency on one; it is *told* whether one exists
/// through [VoiceDuplexConfig.fullDuplex]'s `echoCancelled` argument. The layer
/// that actually builds the canceller — `voice_flutter`'s
/// `VoiceFullDuplexSetup` — is what passes it.
///
/// ## What barge-in means in each mode
///
/// | | half duplex | full duplex |
/// |---|---|---|
/// | voice activity during playback | interrupts the turn | ignored, unless [interruptAfterSustainedSpeech] is set |
/// | committed final transcript | starts a new turn | starts a new turn |
/// | `interruptTurn()` | interrupts the turn | interrupts the turn |
///
/// A committed transcript supersedes the in-flight turn in *both* modes: the
/// user finished saying something, so the response to it replaces the response
/// they talked over. What full duplex changes is that merely making a sound no
/// longer does that.
final class VoiceDuplexConfig {
  const VoiceDuplexConfig._({
    required this.requestedMode,
    required this.mode,
    required this.echoCancelled,
    required this.fallback,
    required this.interruptAfterSustainedSpeech,
  });

  /// The default policy: recognition is gated while the assistant speaks.
  const VoiceDuplexConfig.halfDuplex()
    : requestedMode = VoiceDuplexMode.halfDuplex,
      mode = VoiceDuplexMode.halfDuplex,
      echoCancelled = false,
      fallback = VoiceEchoCancellationFallback.halfDuplex,
      interruptAfterSustainedSpeech = null;

  /// Requests full duplex, resolving [mode] against [echoCancelled].
  ///
  /// [echoCancelled] states whether the microphone handed to the controller is
  /// actually echo-cancelled. When it is `false`, [fallback] decides whether
  /// this degrades to half duplex or proceeds with the echo risk.
  ///
  /// [interruptAfterSustainedSpeech] opts into interrupting playback on
  /// sustained user speech, on top of the transcript-level barge-in that always
  /// applies. It is dwell time measured from the voice-activity *start* event,
  /// so it stacks on the detector's own `minimumSpeech` hysteresis rather than
  /// replacing it: a detector configured with 100 ms of hysteresis and a 400 ms
  /// threshold here interrupts after roughly 500 ms of continuous speech.
  /// Leaving it `null` — the default — means only an explicit
  /// `interruptTurn()` or a committed transcript ends playback early.
  factory VoiceDuplexConfig.fullDuplex({
    bool echoCancelled = true,
    VoiceEchoCancellationFallback fallback =
        VoiceEchoCancellationFallback.halfDuplex,
    Duration? interruptAfterSustainedSpeech,
  }) {
    if (interruptAfterSustainedSpeech != null &&
        interruptAfterSustainedSpeech <= Duration.zero) {
      throw ArgumentError.value(
        interruptAfterSustainedSpeech,
        'interruptAfterSustainedSpeech',
        'Must be positive. Use null to never interrupt on voice activity '
            'alone, which is the point of full duplex.',
      );
    }
    final bool full =
        echoCancelled ||
        fallback == VoiceEchoCancellationFallback.acceptEchoRisk;
    return VoiceDuplexConfig._(
      requestedMode: VoiceDuplexMode.fullDuplex,
      mode: full ? VoiceDuplexMode.fullDuplex : VoiceDuplexMode.halfDuplex,
      echoCancelled: echoCancelled,
      fallback: fallback,
      interruptAfterSustainedSpeech: full
          ? interruptAfterSustainedSpeech
          : null,
    );
  }

  /// Mode the application asked for.
  final VoiceDuplexMode requestedMode;

  /// Mode actually in effect.
  final VoiceDuplexMode mode;

  /// Whether the microphone reaching the controller is echo-cancelled.
  final bool echoCancelled;

  /// Policy applied when full duplex was requested without echo cancellation.
  final VoiceEchoCancellationFallback fallback;

  /// Dwell time before sustained speech interrupts playback, or `null` when
  /// voice activity alone never interrupts.
  ///
  /// Always `null` in [VoiceDuplexMode.halfDuplex], where voice activity
  /// interrupts immediately.
  final Duration? interruptAfterSustainedSpeech;

  /// Whether full duplex was requested but could not be honored.
  ///
  /// This is the surfaced degradation signal. It is a resolved property rather
  /// than a stream event because the resolution is deterministic and complete
  /// before `start()` is ever called, so there is nothing to wait for: the very
  /// first snapshot a listener sees already carries the honest
  /// `VoiceConversationSnapshot.duplexMode`.
  bool get isDegraded => requestedMode != mode;

  /// Whether full duplex is running against an uncancelled microphone.
  ///
  /// `true` only under [VoiceEchoCancellationFallback.acceptEchoRisk]. Expect
  /// the recognizer to hear the assistant.
  bool get acceptsEchoRisk =>
      mode == VoiceDuplexMode.fullDuplex && !echoCancelled;

  @override
  String toString() =>
      'VoiceDuplexConfig(mode: ${mode.name}, requested: ${requestedMode.name}, '
      'echoCancelled: $echoCancelled, '
      'interruptAfterSustainedSpeech: $interruptAfterSustainedSpeech)';
}
