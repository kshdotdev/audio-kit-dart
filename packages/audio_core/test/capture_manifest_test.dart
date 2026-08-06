import 'dart:convert';

import 'package:audio_core/audio_core.dart';
import 'package:test/test.dart';

void main() {
  test('capture manifest survives a JSON encoding round trip', () {
    final AudioCaptureSessionManifest manifest = AudioCaptureSessionManifest(
      sessionId: 'meeting-42',
      requestedMode: RequestedAudioCaptureMode.microphoneAndSystemAudio,
      tracks: <CapturedAudioTrackManifest>[
        CapturedAudioTrackManifest(
          trackId: 'microphone',
          artifactId: 'audio:meeting-42:microphone',
          source: AudioCaptureSourceIdentity(
            sourceId: 'mic-source',
            kind: AudioCaptureSourceKind.microphone,
            providerId: 'audio_flutter',
            nativeSourceId: 'built-in-mic',
            displayName: 'MacBook Microphone',
          ),
          format: AudioFormat(sampleRate: 48000, channels: 1),
          startOffset: const Duration(microseconds: 1250),
          frameCount: 96000,
        ),
      ],
      degradationReason: AudioCaptureDegradationReason(
        code: 'system_audio_permission_denied',
        message: 'Only the microphone track was captured.',
      ),
    );

    final Map<String, Object?> decoded =
        (jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>)
            .cast<String, Object?>();
    final AudioCaptureSessionManifest restored =
        AudioCaptureSessionManifest.fromJson(decoded);

    expect(restored.toJson(), manifest.toJson());
    expect(restored.tracks, isNot(same(manifest.tracks)));
    expect(
      () => restored.tracks.add(manifest.tracks.single),
      throwsUnsupportedError,
    );
  });

  test('capture manifest validates versions and stable IDs', () {
    final CapturedAudioTrackManifest track = CapturedAudioTrackManifest(
      trackId: 'system',
      artifactId: 'audio:system',
      source: AudioCaptureSourceIdentity(
        sourceId: 'system-source',
        kind: AudioCaptureSourceKind.systemAudio,
      ),
      format: AudioFormat(sampleRate: 16000, channels: 1),
      startOffset: Duration.zero,
    );

    expect(
      () => AudioCaptureSessionManifest(
        sessionId: 'session',
        requestedMode: RequestedAudioCaptureMode.systemAudio,
        tracks: <CapturedAudioTrackManifest>[track, track],
      ),
      throwsArgumentError,
    );
    expect(
      () => AudioCaptureSessionManifest.fromJson(<String, Object?>{
        'schemaVersion': 2,
        'sessionId': 'session',
        'requestedMode': 'systemAudio',
        'tracks': <Object?>[],
      }),
      throwsFormatException,
    );
    expect(
      () => CapturedAudioTrackManifest(
        trackId: 'track',
        artifactId: 'artifact',
        source: track.source,
        format: track.format,
        startOffset: const Duration(microseconds: -1),
      ),
      throwsArgumentError,
    );
  });
}
