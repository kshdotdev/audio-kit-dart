/// Channel identifiers and the wire contract shared by the Dart platform
/// implementation and the C++ plugin.
///
/// # Wire format
///
/// Two channels, both using the standard method codec:
///
/// * [kWindowsMethodChannel] carries every request/response.
/// * [kWindowsEventChannel] carries session lifecycle events **only**. Audio
///   never travels over the event channel: frames are pulled on demand by
///   [kMethodReadCaptureFrames], which is what keeps backpressure structural
///   rather than something the Dart side has to reconstruct.
///
/// ## Requests
///
/// Every method takes a single `Map<String, Object?>` argument (or none) and
/// returns either `null`, a scalar, a `List`, or a map. Field names below are
/// the exact keys both sides use.
///
/// ```text
/// prepareCapture {
///   kind: 'microphone' | 'systemAudio',
///   sampleRate: int, channelCount: int,
///   frameDurationMicros: int, maxBufferedDurationMicros: int,
///   overflowPolicy: 'dropOldest' | 'dropNewest' | 'failCapture',
///   inputDeviceId: String?,       // endpoint id; null selects the default
/// } -> {
///   sessionId: int, sourceId: String, trackId: String, clockId: String,
///   sampleRate: int, channelCount: int,
/// }
///
/// startCapture      { sessionId: int } -> null
/// stopCapture       { sessionId: int } -> null
/// abortCapture      { sessionId: int } -> null
/// disposeCapture    { sessionId: int } -> null
///
/// readCaptureFrames { sessionId: int, maxFrames: int, timeoutMillis: int } -> {
///   endOfStream: bool,
///   frames: [ {
///     sessionId: int, sequence: int, sampleOffset: int,
///     timestampMicros: int, droppedFramesBefore: int,
///     samples: Uint8List,   // interleaved float32, little-endian
///   } ],
/// }
///
/// listAudioInputDevices    {} -> [ { id: String, label: String, isDefault: bool } ]
/// listSystemAudioSources   {} -> [ { id: String, label: String, isDefault: bool } ]
/// listAudioProcesses       {} -> []            // always empty, see README
/// isSystemAudioCaptureSupported {} -> bool
/// requestSystemAudioCapturePermission {} -> bool
///
/// preparePlayback { sampleRate: int, channelCount: int,
///                   maxBufferedDurationMicros: int } -> {
///   sessionId: int, clockId: String, sampleRate: int, channelCount: int,
/// }
/// startPlayback        { sessionId: int } -> null
/// writePlaybackFrames  { sessionId: int, frames: [ { samples: Uint8List } ] } -> null
/// finishPlayback       { sessionId: int } -> null
/// abortPlayback        { sessionId: int } -> null
/// disposePlayback      { sessionId: int } -> null
/// ```
///
/// ## Events
///
/// One stream for every session; the Dart side demultiplexes by `sessionId`.
///
/// ```text
/// { sessionId: int,
///   phase: 'prepared'|'starting'|'running'|'interrupted'|'stopping'|'stopped'|'failed',
///   code: String?, message: String?,
///   receivingAudio: bool?, callbackCount: int? }
/// ```
///
/// ## Sample encoding
///
/// Samples cross as raw little-endian float32 bytes in a `Uint8List` rather
/// than a `Float32List`. The byte blob is unambiguous across codec versions and
/// decodes without a copy when the incoming view happens to be 4-byte aligned.
/// Windows is little-endian on every architecture Flutter targets, so the host
/// interpretation and the wire order always agree.
library;

/// Method channel carrying every request and response.
const String kWindowsMethodChannel =
    'dev.kshdotdev.audio_kit/audio_flutter_windows';

/// Event channel carrying session lifecycle events only, never audio.
const String kWindowsEventChannel =
    'dev.kshdotdev.audio_kit/audio_flutter_windows/events';

// Capture.
const String kMethodPrepareCapture = 'prepareCapture';
const String kMethodStartCapture = 'startCapture';
const String kMethodReadCaptureFrames = 'readCaptureFrames';
const String kMethodStopCapture = 'stopCapture';
const String kMethodAbortCapture = 'abortCapture';
const String kMethodDisposeCapture = 'disposeCapture';

// Capability and enumeration.
const String kMethodIsSystemAudioCaptureSupported =
    'isSystemAudioCaptureSupported';
const String kMethodRequestSystemAudioCapturePermission =
    'requestSystemAudioCapturePermission';
const String kMethodListAudioInputDevices = 'listAudioInputDevices';
const String kMethodListSystemAudioSources = 'listSystemAudioSources';
const String kMethodListAudioProcesses = 'listAudioProcesses';

// Playback.
const String kMethodPreparePlayback = 'preparePlayback';
const String kMethodStartPlayback = 'startPlayback';
const String kMethodWritePlaybackFrames = 'writePlaybackFrames';
const String kMethodFinishPlayback = 'finishPlayback';
const String kMethodAbortPlayback = 'abortPlayback';
const String kMethodDisposePlayback = 'disposePlayback';

/// Time a capture may deliver no frames before the native watchdog fails it.
const Duration kWindowsCaptureStallTimeout = Duration(seconds: 2);
