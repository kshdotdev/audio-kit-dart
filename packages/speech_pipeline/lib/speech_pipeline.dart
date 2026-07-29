/// Live transcription over batch speech providers.
///
/// Cuts a continuous capture stream into decodable windows, gates silence,
/// filters recognizer hallucinations, and removes microphone echo of the
/// far-track audio.
library;

export 'src/batch_pipeline.dart';
export 'src/echo_filter.dart';
export 'src/hallucination_filters.dart';
export 'src/speech_activity.dart';
export 'src/transcript_segment.dart';
export 'src/window_cutter.dart';
