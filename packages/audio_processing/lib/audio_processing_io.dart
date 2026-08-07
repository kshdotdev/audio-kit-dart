/// File-backed audio processing utilities for Dart IO platforms.
///
/// Import `package:audio_processing/audio_processing.dart` when only portable
/// processing APIs are needed. This library additionally exports the
/// `dart:io`-backed segmented WAV storage, WAV source and sink, and path-based
/// WAV header repair.
library;

export 'audio_processing.dart';
export 'src/local_segmented_wav_storage.dart';
export 'src/wav_file_recovery.dart';
export 'src/wav_file_sink.dart';
export 'src/wav_file_source.dart';
