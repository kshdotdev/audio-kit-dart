/// Meeting-domain building blocks: detection fusion, recording lifecycle,
/// microphone health, structured outcomes, and speaker labelling.
///
/// Domain logic and stage shapes live here; persistence, transport, and user
/// interface stay in the host application.
library;

export 'src/conferencing_apps.dart';
export 'src/detection.dart';
export 'src/lifecycle.dart';
export 'src/mic_health.dart';
export 'src/outcome.dart';
export 'src/signal_collector.dart';
export 'src/speaker_labels.dart';
