import 'package:flutter_test/flutter_test.dart';
import 'package:speech_fluidaudio/speech_fluidaudio.dart';

/// Pins the public export surface of `package:speech_fluidaudio`.
///
/// Every reference below resolves through the barrel alone, so narrowing or
/// dropping an export turns into a compile-time test failure instead of a
/// silent breaking change for downstream packages.
void main() {
  group('speech_fluidaudio barrel', () {
    test('exports the provider entry points', () {
      expect(<Type>[FluidAudioSpeechProvider, FluidNativeRuntime], isNotEmpty);
    });

    test('exports the provider options', () {
      expect(fluidAudioProviderId, isNotEmpty);
      expect(fluidDiarizationModelId, isNotEmpty);
      expect(<Type>[
        FluidDiarizationOptions,
        FluidEndOfUtteranceChunk,
        FluidEndOfUtteranceOptions,
        FluidRecognitionModel,
        FluidRecognitionOptions,
        FluidRecognitionSource,
        FluidSynthesisEngine,
        FluidSynthesisOptions,
        FluidVocabularyEntry,
      ], isNotEmpty);
    });

    test('exports the injectable runtime seam', () {
      expect(<Type>[
        FluidAudioRuntime,
        FluidBatchAsrDriver,
        FluidDiarizationDriver,
        FluidDiarizationDriverConfiguration,
        FluidDriverBatchAsrResult,
        FluidDriverEndOfUtteranceUpdate,
        FluidDriverSpeakerSegment,
        FluidDriverTokenTiming,
        FluidDriverTranscriptionUpdate,
        FluidDriverTtsChunk,
        FluidDriverVadEvent,
        FluidEndOfUtteranceDriver,
        FluidItnDriver,
        FluidStreamingAsrDriver,
        FluidStreamingAsrDriverConfiguration,
        FluidTranscriptItnDriver,
        FluidTtsDriver,
        FluidTtsDriverConfiguration,
        FluidVadDriver,
      ], isNotEmpty);
    });

    test('exports the streaming session types', () {
      expect(<Type>[
        FluidEndOfUtteranceSession,
        FluidManagedSession,
        FluidStreamingSpeechToTextSession,
        FluidVoiceActivityDetectionSession,
      ], isNotEmpty);
    });

    test('exports the synthesis source types', () {
      expect(<Type>[
        FluidTtsAudioSource,
        FluidTtsAudioSourceSession,
      ], isNotEmpty);
    });

    test('exports the conversion helpers', () {
      expect(<Type>[FluidCollectedAudio, FluidPcm16MonoConverter], isNotEmpty);
      expect(<Function>[
        collectFluidAudio,
        fluidAudioFailure,
        fluidLanguageCode,
        fluidSpeechFailure,
      ], isNotEmpty);
    });
  });
}
