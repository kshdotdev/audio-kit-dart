import 'package:audio_core/audio_core.dart';
import 'package:speech_core/speech_core.dart';

import 'options.dart';

/// Builds a provider-neutral speech failure, preserving an existing one.
SpeechFailure sherpaSpeechFailure(
  String code,
  String stage,
  String message, {
  bool retryable = false,
  Object? cause,
}) {
  if (cause case final SpeechFailure failure) {
    return failure;
  }
  return SpeechFailure(
    code: code,
    stage: stage,
    providerId: sherpaProviderId,
    retryable: retryable,
    safeMessage: message,
    safeCause: cause?.runtimeType.toString(),
  );
}

/// Builds an audio-layer failure for session transitions.
AudioFailure sherpaAudioFailure(
  String code,
  AudioFailureStage stage,
  String message, {
  bool retryable = false,
}) => AudioFailure(
  code: code,
  stage: stage,
  message: message,
  providerId: sherpaProviderId,
  retryable: retryable,
);

/// Normalizes a BCP-47 tag to the bare language subtag sherpa accepts.
String? sherpaLanguageCode(String? languageTag) {
  final value = languageTag?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }
  return value.split(RegExp('[-_]')).first.toLowerCase();
}
