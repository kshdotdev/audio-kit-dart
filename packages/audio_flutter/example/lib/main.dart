// Minimal desktop host for the audio_flutter federated plugin.
//
// This app exists to be built, not to be pretty: `flutter build <platform>` on
// it is what compiles every platform implementation the app depends on. The
// buttons cover the two operations that need a real device to mean anything —
// input-device enumeration and a capture start/stop round trip.

import 'dart:async';
import 'dart:math' as math;

import 'package:audio_core/audio_core.dart';
import 'package:audio_flutter/audio_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const AudioFlutterExampleApp());
}

/// Root widget of the example host.
class AudioFlutterExampleApp extends StatelessWidget {
  /// Creates the example host.
  const AudioFlutterExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'audio_flutter example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    home: const CapturePage(),
  );
}

/// Single screen exercising device listing and capture start/stop.
class CapturePage extends StatefulWidget {
  /// Creates the capture screen.
  const CapturePage({super.key});

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  static final AudioFormat _format = AudioFormat(
    sampleRate: 48000,
    channels: 1,
  );

  final FlutterAudioDevices _devices = FlutterAudioDevices();

  List<AudioInputDevice> _inputs = const <AudioInputDevice>[];
  String? _selectedDeviceId;
  AudioCaptureType _captureType = AudioCaptureType.microphone;
  FlutterAudioCaptureSession? _session;
  StreamSubscription<AudioFrame>? _frames;
  int _frameCount = 0;
  double _peak = 0;
  String _status = 'idle';
  bool _busy = false;

  bool get _capturing => _session != null;

  @override
  void initState() {
    super.initState();
    unawaited(_listDevices());
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    unawaited(_session?.close());
    super.dispose();
  }

  Future<void> _listDevices() => _guard('listing devices', () async {
    final List<AudioInputDevice> inputs = await _devices.listInputs();
    if (!mounted) {
      return;
    }
    setState(() {
      _inputs = inputs;
      if (!inputs.any(
        (AudioInputDevice device) => device.id == _selectedDeviceId,
      )) {
        _selectedDeviceId = null;
      }
      _status = 'found ${inputs.length} input device(s)';
    });
  });

  Future<void> _startCapture() => _guard('starting capture', () async {
    if (_capturing) {
      return;
    }
    final FlutterAudioCaptureSource source = FlutterAudioCaptureSource(
      FlutterAudioCaptureConfig(
        type: _captureType,
        format: _format,
        overflowPolicy: AudioCaptureOverflowPolicy.dropOldest,
        inputDeviceId: _captureType == AudioCaptureType.microphone
            ? _selectedDeviceId
            : null,
      ),
    );
    final FlutterAudioCaptureSession session = await source.prepare();
    _frames = session.frames.listen(
      _onFrame,
      onError: (Object error) => _report('capture', error),
      cancelOnError: false,
    );
    setState(() {
      _session = session;
      _frameCount = 0;
      _peak = 0;
      _status = 'starting';
    });
    await session.start();
    if (mounted) {
      setState(() => _status = 'capturing from ${session.sourceId}');
    }
  });

  Future<void> _stopCapture() => _guard('stopping capture', () async {
    final FlutterAudioCaptureSession? session = _session;
    if (session == null) {
      return;
    }
    try {
      await session.stop();
    } finally {
      await _frames?.cancel();
      await session.close();
      _frames = null;
      if (mounted) {
        setState(() {
          _session = null;
          _status = 'stopped after $_frameCount frame(s)';
        });
      }
    }
  });

  void _onFrame(AudioFrame frame) {
    double peak = 0;
    for (final double sample in frame.samples) {
      peak = math.max(peak, sample.abs());
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _frameCount++;
      _peak = peak;
    });
  }

  Future<void> _guard(String action, Future<void> Function() body) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await body();
    } catch (error) {
      _report(action, error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _report(String action, Object error) {
    if (!mounted) {
      return;
    }
    setState(() => _status = 'error while $action: $error');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('audio_flutter example')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: _busy ? null : () => unawaited(_listDevices()),
                child: const Text('List devices'),
              ),
              FilledButton(
                onPressed: _busy || _capturing
                    ? null
                    : () => unawaited(_startCapture()),
                child: const Text('Start capture'),
              ),
              FilledButton(
                onPressed: _busy || !_capturing
                    ? null
                    : () => unawaited(_stopCapture()),
                child: const Text('Stop capture'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<AudioCaptureType>(
            segments: const <ButtonSegment<AudioCaptureType>>[
              ButtonSegment<AudioCaptureType>(
                value: AudioCaptureType.microphone,
                label: Text('Microphone'),
              ),
              ButtonSegment<AudioCaptureType>(
                value: AudioCaptureType.systemAudio,
                label: Text('System audio'),
              ),
            ],
            selected: <AudioCaptureType>{_captureType},
            onSelectionChanged: _capturing
                ? null
                : (Set<AudioCaptureType> selection) =>
                      setState(() => _captureType = selection.single),
          ),
          const SizedBox(height: 12),
          Text('Status: $_status'),
          Text('Frames: $_frameCount   Peak: ${_peak.toStringAsFixed(4)}'),
          const Divider(height: 24),
          Expanded(
            child: ListView.builder(
              itemCount: _inputs.length,
              itemBuilder: (BuildContext context, int index) {
                final AudioInputDevice device = _inputs[index];
                return ListTile(
                  onTap: _capturing
                      ? null
                      : () => setState(() => _selectedDeviceId = device.id),
                  leading: Icon(
                    _selectedDeviceId == device.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(device.label),
                  subtitle: Text(
                    device.isDefault ? '${device.id} (default)' : device.id,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
