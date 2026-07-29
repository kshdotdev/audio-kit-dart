/// Cross-platform speech provider backed by sherpa-onnx.
///
/// Implements the `speech_core` contracts for streaming and batch recognition,
/// voice-activity detection, diarization, and speaker embeddings on macOS,
/// Windows, Linux, iOS, and Android — the inference floor for platforms
/// without an on-device Apple runtime.
library;

export 'src/conversion.dart' show SherpaCollectedAudio, sherpaSampleRate;
export 'src/model_registry.dart'
    show SherpaHttpClientFactory, SherpaInstallProgress, SherpaModelRegistry;
export 'src/models.dart'
    show
        SherpaArchivedFileModel,
        SherpaDiarizationModelPaths,
        SherpaFileModel,
        SherpaRecognitionModel,
        SherpaRecognitionModelPaths;
export 'src/native_runtime.dart' show SherpaNativeRuntime, ensureSherpaBindings;
export 'src/options.dart'
    show
        SherpaDiarizationOptions,
        SherpaRecognitionModelKind,
        SherpaRecognitionOptions,
        SherpaStreamingRecognitionOptions,
        SherpaVoiceActivityOptions,
        sherpaProviderId;
export 'src/provider.dart' show SherpaSpeechProvider;
export 'src/runtime.dart'
    show
        SherpaBatchAsrConfiguration,
        SherpaBatchAsrDriver,
        SherpaDiarizationConfiguration,
        SherpaDiarizationDriver,
        SherpaDriverSpeakerSpan,
        SherpaDriverSpeechSpan,
        SherpaDriverStreamingUpdate,
        SherpaDriverTranscript,
        SherpaRuntime,
        SherpaStreamingAsrConfiguration,
        SherpaStreamingAsrDriver,
        SherpaVadConfiguration,
        SherpaVadDriver;
export 'src/sessions.dart'
    show SherpaStreamingRecognitionSession, SherpaVoiceActivitySession;
