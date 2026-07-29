/// Capabilities a speech provider or model can advertise.
///
/// Append new members at the end, and serialize by `name` rather than `index`
/// anywhere a capability set is persisted.
enum SpeechCapability {
  streamingSpeechToText,
  batchSpeechToText,
  textToSpeech,
  voiceActivityDetection,
  endOfUtterance,
  diarization,

  /// Exposes the speaker vectors behind diarization, not only the labels.
  ///
  /// Separate from [diarization] on purpose: a provider can cluster speakers
  /// without surfacing vectors, so declaring [diarization] says nothing about
  /// whether `SpeakerSegment.embedding` will be populated.
  speakerEmbedding,

  /// Converts spoken-form text to written form, such as `twenty five dollars`
  /// to `$25`.
  inverseTextNormalization,

  /// Scores whether a window of speech ended a conversational turn.
  ///
  /// Distinct from [endOfUtterance], which reports that speech stopped: this
  /// answers whether the speaker was *finished*, which is the difference
  /// between waiting through a mid-sentence pause and interrupting.
  turnCompletion,
}

/// Metadata for a provider-neutral speech model.
final class SpeechModelDescriptor {
  SpeechModelDescriptor({
    required this.id,
    required this.providerId,
    required this.displayName,
    required Set<SpeechCapability> capabilities,
    Set<String> languageTags = const <String>{},
    this.isLocal = false,
  }) : capabilities = Set<SpeechCapability>.unmodifiable(capabilities),
       languageTags = Set<String>.unmodifiable(languageTags) {
    _requireIdentifier(id, 'id');
    _requireIdentifier(providerId, 'providerId');
  }

  /// Stable provider-scoped model ID.
  final String id;

  /// Stable provider ID.
  final String providerId;

  /// Human-readable model name.
  final String displayName;

  /// Features supported by this model.
  final Set<SpeechCapability> capabilities;

  /// BCP-47 language tags. An empty set means provider-defined or multilingual.
  final Set<String> languageTags;

  /// Whether inference occurs on the local device.
  final bool isLocal;
}

/// Metadata for a provider-neutral synthesized voice.
final class SpeechVoiceDescriptor {
  SpeechVoiceDescriptor({
    required this.id,
    required this.providerId,
    required this.displayName,
    Set<String> languageTags = const <String>{},
    this.isLocal = false,
  }) : languageTags = Set<String>.unmodifiable(languageTags) {
    _requireIdentifier(id, 'id');
    _requireIdentifier(providerId, 'providerId');
  }

  /// Stable provider-scoped voice ID.
  final String id;

  /// Stable provider ID.
  final String providerId;

  /// Human-readable voice name.
  final String displayName;

  /// BCP-47 language tags.
  final Set<String> languageTags;

  /// Whether synthesis occurs on the local device.
  final bool isLocal;
}

/// Metadata and capabilities exposed by a speech provider.
final class SpeechProviderDescriptor {
  SpeechProviderDescriptor({
    required this.id,
    required this.displayName,
    required Set<SpeechCapability> capabilities,
    Iterable<SpeechModelDescriptor> models = const <SpeechModelDescriptor>[],
    Iterable<SpeechVoiceDescriptor> voices = const <SpeechVoiceDescriptor>[],
  }) : capabilities = Set<SpeechCapability>.unmodifiable(capabilities),
       models = List<SpeechModelDescriptor>.unmodifiable(models),
       voices = List<SpeechVoiceDescriptor>.unmodifiable(voices) {
    _requireIdentifier(id, 'id');
    for (final model in this.models) {
      if (model.providerId != id) {
        throw ArgumentError.value(
          model.providerId,
          'models',
          'Model providerId must match provider ID "$id".',
        );
      }
    }
    for (final voice in this.voices) {
      if (voice.providerId != id) {
        throw ArgumentError.value(
          voice.providerId,
          'voices',
          'Voice providerId must match provider ID "$id".',
        );
      }
    }
  }

  /// Stable provider ID, such as `deepgram` or `mlx`.
  final String id;

  /// Human-readable provider name.
  final String displayName;

  /// Provider-level capabilities.
  final Set<SpeechCapability> capabilities;

  /// Available provider models.
  final List<SpeechModelDescriptor> models;

  /// Available synthesized voices.
  final List<SpeechVoiceDescriptor> voices;

  /// Whether this provider advertises [capability].
  bool supports(SpeechCapability capability) =>
      capabilities.contains(capability);
}

void _requireIdentifier(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
}
