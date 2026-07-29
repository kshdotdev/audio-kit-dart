/// FluidAudio adapters for the provider-neutral audio and speech contracts.
library;

export 'src/conversion.dart'
    show
        FluidCollectedAudio,
        FluidPcm16MonoConverter,
        collectFluidAudio,
        fluidLanguageCode,
        fluidSpeechFailure;
export 'src/drivers.dart';
export 'src/native_runtime.dart';
export 'src/options.dart';
export 'src/provider.dart';
export 'src/session_support.dart' show FluidManagedSession, fluidAudioFailure;
export 'src/sessions.dart'
    show
        FluidEndOfUtteranceSession,
        FluidStreamingSpeechToTextSession,
        FluidVoiceActivityDetectionSession;
export 'src/tts_source.dart'
    show FluidTtsAudioSource, FluidTtsAudioSourceSession;
