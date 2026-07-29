// The model catalog, on-disk layout, and install flow in this file and in
// `model_registry.dart` are derived from Control Center
// (https://github.com/SamuelAlev/control-center), MIT (c) 2026 Samuel Alev.
// See the NOTICE file at the root of this package.

import 'package:speech_core/speech_core.dart';

import 'options.dart';

/// A recognition model installable from the k2-fsa sherpa-onnx releases.
///
/// Every entry is a `.tar.bz2` archive that unpacks into a single top-level
/// directory named [unpackedDirName].
final class SherpaRecognitionModel {
  /// Creates a recognition model entry.
  const SherpaRecognitionModel({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.archiveUrl,
    required this.archiveBytes,
    required this.unpackedDirName,
    required this.encoderFile,
    required this.decoderFile,
    required this.tokensFile,
    this.joinerFile,
    this.languageTags = const <String>{},
    this.isMultilingual = false,
  }) : assert(
         kind != SherpaRecognitionModelKind.transducer || joinerFile != null,
         'A transducer model must declare a joinerFile.',
       );

  /// Stable model ID, matching the upstream archive name.
  final String id;

  /// Human-readable model name.
  final String displayName;

  /// Decoding family, which selects the sherpa sub-config to populate.
  final SherpaRecognitionModelKind kind;

  /// Download location of the `.tar.bz2` archive.
  final String archiveUrl;

  /// Approximate archive size, used only for download progress.
  final int archiveBytes;

  /// Top-level directory the archive unpacks into.
  final String unpackedDirName;

  /// Encoder file name relative to [unpackedDirName].
  final String encoderFile;

  /// Decoder file name relative to [unpackedDirName].
  final String decoderFile;

  /// Token table file name relative to [unpackedDirName].
  final String tokensFile;

  /// Joiner file name relative to [unpackedDirName], transducers only.
  final String? joinerFile;

  /// BCP-47 tags this model covers. Empty means provider-defined.
  final Set<String> languageTags;

  /// Whether the model spans multiple languages.
  final bool isMultilingual;

  /// NVIDIA Parakeet TDT 0.6B v3 int8 — the cross-platform default.
  ///
  /// A FastConformer transducer covering 25 European languages that decodes
  /// substantially faster than Whisper at comparable accuracy, with token
  /// timings, on the same ONNX Runtime everywhere.
  static const SherpaRecognitionModel parakeetTdtV3 = SherpaRecognitionModel(
    id: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',
    displayName: 'Parakeet TDT 0.6B v3 (multilingual)',
    kind: SherpaRecognitionModelKind.transducer,
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2',
    archiveBytes: 600 * 1024 * 1024,
    unpackedDirName: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',
    encoderFile: 'encoder.int8.onnx',
    decoderFile: 'decoder.int8.onnx',
    joinerFile: 'joiner.int8.onnx',
    tokensFile: 'tokens.txt',
    isMultilingual: true,
  );

  /// NVIDIA Parakeet TDT 0.6B v2 int8 — English only, smaller than v3.
  static const SherpaRecognitionModel parakeetTdtV2 = SherpaRecognitionModel(
    id: 'sherpa-onnx-nemo-parakeet_tdt-0.6b-v2-int8',
    displayName: 'Parakeet TDT 0.6B v2 (English)',
    kind: SherpaRecognitionModelKind.transducer,
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-nemo-parakeet_tdt-0.6b-v2-int8.tar.bz2',
    archiveBytes: 480 * 1024 * 1024,
    unpackedDirName: 'sherpa-onnx-nemo-parakeet_tdt-0.6b-v2-int8',
    encoderFile: 'encoder.int8.onnx',
    decoderFile: 'decoder.int8.onnx',
    joinerFile: 'joiner.int8.onnx',
    tokensFile: 'tokens.txt',
    languageTags: <String>{'en'},
  );

  /// Whisper large-v3-turbo int8 — the widest language coverage, slower.
  static const SherpaRecognitionModel whisperLargeV3Turbo =
      SherpaRecognitionModel(
        id: 'sherpa-onnx-whisper-large-v3-turbo',
        displayName: 'Whisper large-v3-turbo (multilingual)',
        kind: SherpaRecognitionModelKind.whisper,
        archiveUrl:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
            'asr-models/sherpa-onnx-whisper-large-v3-turbo.tar.bz2',
        archiveBytes: 626 * 1024 * 1024,
        unpackedDirName: 'sherpa-onnx-whisper-large-v3-turbo',
        encoderFile: 'large-v3-turbo-encoder.int8.onnx',
        decoderFile: 'large-v3-turbo-decoder.int8.onnx',
        tokensFile: 'large-v3-turbo-tokens.txt',
        isMultilingual: true,
      );

  /// Whisper base.en int8 — the low-disk English fallback.
  static const SherpaRecognitionModel whisperBaseEn = SherpaRecognitionModel(
    id: 'sherpa-onnx-whisper-base.en',
    displayName: 'Whisper base.en',
    kind: SherpaRecognitionModelKind.whisper,
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-whisper-base.en.tar.bz2',
    archiveBytes: 198 * 1024 * 1024,
    unpackedDirName: 'sherpa-onnx-whisper-base.en',
    encoderFile: 'base.en-encoder.int8.onnx',
    decoderFile: 'base.en-decoder.int8.onnx',
    tokensFile: 'base.en-tokens.txt',
    languageTags: <String>{'en'},
  );

  /// Every recognition model, default first.
  static const List<SherpaRecognitionModel> all = <SherpaRecognitionModel>[
    parakeetTdtV3,
    parakeetTdtV2,
    whisperLargeV3Turbo,
    whisperBaseEn,
  ];

  /// The model used when a request names none.
  static const SherpaRecognitionModel defaultModel = parakeetTdtV3;
}

/// A single-file model downloaded without an archive.
final class SherpaFileModel {
  /// Creates a bare-file model entry.
  const SherpaFileModel({
    required this.id,
    required this.displayName,
    required this.url,
    required this.fileName,
    required this.sizeBytes,
  });

  /// Stable model ID.
  final String id;

  /// Human-readable model name.
  final String displayName;

  /// Download location of the `.onnx` file.
  final String url;

  /// File name written under the install directory.
  final String fileName;

  /// Approximate size, used only for download progress.
  final int sizeBytes;

  /// Silero VAD v4, the speech gate used by [SherpaVoiceActivityOptions].
  static const SherpaFileModel sileroVad = SherpaFileModel(
    id: 'silero-vad',
    displayName: 'Silero VAD',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'silero_vad.onnx',
    fileName: 'silero_vad.onnx',
    sizeBytes: 2 * 1024 * 1024,
  );

  /// WeSpeaker ResNet34 speaker-embedding model (VoxCeleb, English).
  ///
  /// The upstream release tag misspells "recognition" as `recongition`; the URL
  /// keeps the typo verbatim because that is the tag that actually resolves.
  static const SherpaFileModel wespeakerResnet34 = SherpaFileModel(
    id: 'wespeaker-en-voxceleb-resnet34-lm',
    displayName: 'WeSpeaker ResNet34 (VoxCeleb, English)',
    url:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
        'speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx',
    fileName: 'wespeaker_en_voxceleb_resnet34_LM.onnx',
    sizeBytes: 26 * 1024 * 1024,
  );
}

/// An archived model whose payload is a single file inside the tarball.
final class SherpaArchivedFileModel {
  /// Creates an archived single-file model entry.
  const SherpaArchivedFileModel({
    required this.id,
    required this.displayName,
    required this.archiveUrl,
    required this.archiveBytes,
    required this.modelFile,
  });

  /// Stable model ID.
  final String id;

  /// Human-readable model name.
  final String displayName;

  /// Download location of the `.tar.bz2` archive.
  final String archiveUrl;

  /// Approximate archive size, used only for download progress.
  final int archiveBytes;

  /// Model path relative to the install directory, including the archive's
  /// own top-level folder.
  final String modelFile;

  /// pyannote segmentation 3.0, the diarization segmenter.
  static const SherpaArchivedFileModel pyannoteSegmentation =
      SherpaArchivedFileModel(
        id: 'pyannote-segmentation-3-0',
        displayName: 'pyannote segmentation 3.0',
        archiveUrl:
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
            'speaker-segmentation-models/'
            'sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
        archiveBytes: 9 * 1024 * 1024,
        modelFile: 'sherpa-onnx-pyannote-segmentation-3-0/model.onnx',
      );
}

/// Resolved on-disk paths for a recognition model.
final class SherpaRecognitionModelPaths {
  /// Creates resolved recognition paths.
  const SherpaRecognitionModelPaths({
    required this.model,
    required this.encoder,
    required this.decoder,
    required this.tokens,
    this.joiner,
  });

  /// The catalog entry these paths belong to.
  final SherpaRecognitionModel model;

  /// Absolute encoder path.
  final String encoder;

  /// Absolute decoder path.
  final String decoder;

  /// Absolute token table path.
  final String tokens;

  /// Absolute joiner path, transducers only.
  final String? joiner;
}

/// Resolved on-disk paths for the diarization model pair.
final class SherpaDiarizationModelPaths {
  /// Creates resolved diarization paths.
  const SherpaDiarizationModelPaths({
    required this.segmentation,
    required this.embedding,
    required this.embeddingModelId,
  });

  /// Absolute pyannote segmentation path.
  final String segmentation;

  /// Absolute speaker-embedding model path.
  final String embedding;

  /// Model ID stamped onto every [SpeakerEmbedding] this pair produces.
  ///
  /// Embeddings from different models are not comparable, so the ID travels
  /// with the vector rather than being assumed by the caller.
  final String embeddingModelId;
}

/// Provider descriptors for the sherpa-onnx catalog.
///
/// Streaming recognition is deliberately absent: sherpa exposes an
/// `OnlineRecognizer`, but this package does not wire it yet, and a capability
/// is a promise rather than an aspiration.
SpeechProviderDescriptor buildSherpaDescriptor() {
  final models = <SpeechModelDescriptor>[
    for (final model in SherpaRecognitionModel.all)
      SpeechModelDescriptor(
        id: model.id,
        providerId: sherpaProviderId,
        displayName: model.displayName,
        capabilities: const <SpeechCapability>{
          SpeechCapability.batchSpeechToText,
        },
        languageTags: model.languageTags,
        isLocal: true,
      ),
    SpeechModelDescriptor(
      id: SherpaFileModel.sileroVad.id,
      providerId: sherpaProviderId,
      displayName: SherpaFileModel.sileroVad.displayName,
      capabilities: const <SpeechCapability>{
        SpeechCapability.voiceActivityDetection,
      },
      isLocal: true,
    ),
    SpeechModelDescriptor(
      id: SherpaArchivedFileModel.pyannoteSegmentation.id,
      providerId: sherpaProviderId,
      displayName: SherpaArchivedFileModel.pyannoteSegmentation.displayName,
      capabilities: const <SpeechCapability>{SpeechCapability.diarization},
      isLocal: true,
    ),
    SpeechModelDescriptor(
      id: SherpaFileModel.wespeakerResnet34.id,
      providerId: sherpaProviderId,
      displayName: SherpaFileModel.wespeakerResnet34.displayName,
      capabilities: const <SpeechCapability>{SpeechCapability.speakerEmbedding},
      languageTags: const <String>{'en'},
      isLocal: true,
    ),
  ];

  return SpeechProviderDescriptor(
    id: sherpaProviderId,
    displayName: 'sherpa-onnx',
    capabilities: const <SpeechCapability>{
      SpeechCapability.batchSpeechToText,
      SpeechCapability.voiceActivityDetection,
      SpeechCapability.diarization,
      SpeechCapability.speakerEmbedding,
    },
    models: models,
  );
}
