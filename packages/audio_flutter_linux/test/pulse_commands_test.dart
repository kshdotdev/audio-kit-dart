import 'package:audio_flutter_linux/audio_flutter_linux.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('capture command assembly', () {
    test('requests the exact format from parecord and pw-record', () {
      final List<List<String>> commands = captureCommands(
        format: const PlatformPcmFormat(sampleRate: 16000, channelCount: 1),
        target: 'alsa_output.analog-stereo.monitor',
      );

      expect(commands.first, <String>[
        'parecord',
        '--raw',
        '--rate=16000',
        '--channels=1',
        '--format=s16le',
        '--device=alsa_output.analog-stereo.monitor',
      ]);
      expect(commands.last, <String>[
        'pw-record',
        '--rate=16000',
        '--channels=1',
        '--format=s16',
        '--target=alsa_output.analog-stereo.monitor',
        '-',
      ]);
    });

    test('omits device selection when no target is resolved', () {
      final List<List<String>> commands = captureCommands(
        format: const PlatformPcmFormat(sampleRate: 44100, channelCount: 2),
        target: null,
      );

      expect(commands.first, isNot(contains(startsWith('--device='))));
      expect(commands.last, isNot(contains(startsWith('--target='))));
      expect(commands.first, contains('--rate=44100'));
      expect(commands.first, contains('--channels=2'));
    });

    test('playback mirrors the capture format arguments', () {
      final List<List<String>> commands = playbackCommands(
        format: const PlatformPcmFormat(sampleRate: 24000, channelCount: 2),
      );

      expect(commands.first, <String>[
        'paplay',
        '--raw',
        '--rate=24000',
        '--channels=2',
        '--format=s16le',
      ]);
      expect(commands.last.first, 'pw-play');
      expect(commands.last.last, '-');
    });
  });

  group('format validation', () {
    test('accepts ordinary desktop formats', () {
      expect(
        () => validateCaptureFormat(
          const PlatformPcmFormat(sampleRate: 48000, channelCount: 2),
          frameDuration: const Duration(milliseconds: 100),
        ),
        returnsNormally,
      );
    });

    test('rejects rates and channel counts PulseAudio cannot express', () {
      expect(
        () => validateCaptureFormat(
          const PlatformPcmFormat(sampleRate: 384000, channelCount: 1),
          frameDuration: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<LinuxAudioFormatException>().having(
            (LinuxAudioFormatException e) => e.code,
            'code',
            'UnsupportedSampleRate',
          ),
        ),
      );
      expect(
        () => validateCaptureFormat(
          const PlatformPcmFormat(sampleRate: 48000, channelCount: 64),
          frameDuration: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<LinuxAudioFormatException>().having(
            (LinuxAudioFormatException e) => e.code,
            'code',
            'UnsupportedChannelCount',
          ),
        ),
      );
    });

    test('rejects a frame duration that yields no whole sample frame', () {
      expect(
        () => validateCaptureFormat(
          const PlatformPcmFormat(sampleRate: 8000, channelCount: 1),
          frameDuration: const Duration(microseconds: 100),
        ),
        throwsA(
          isA<LinuxAudioFormatException>().having(
            (LinuxAudioFormatException e) => e.code,
            'code',
            'InvalidFrameDuration',
          ),
        ),
      );
    });

    test('frame sizing counts per-channel frames and interleaved samples', () {
      const PlatformPcmFormat stereo = PlatformPcmFormat(
        sampleRate: 16000,
        channelCount: 2,
      );
      const Duration tenMs = Duration(milliseconds: 10);

      expect(sampleFramesPerFrame(stereo, tenMs), 160);
      expect(samplesPerFrame(stereo, tenMs), 320);
    });
  });

  group('source enumeration', () {
    test('parses names and classifies monitors', () {
      final List<PulseSource> sources = parseSourcesShort(kPactlSourcesShort);

      expect(sources, hasLength(4));
      expect(
        sources
            .where((PulseSource s) => s.isMonitor)
            .map((PulseSource s) => s.name),
        <String>[
          'alsa_output.pci-0000_00_1f.3.analog-stereo.monitor',
          'alsa_output.usb-Focusrite.analog-stereo.monitor',
        ],
      );
      expect(
        sources
            .where((PulseSource s) => !s.isMonitor)
            .map((PulseSource s) => s.name),
        <String>[
          'alsa_input.pci-0000_00_1f.3.analog-stereo',
          'bluez_input.AC_12_2F.headset',
        ],
      );
    });

    test('tolerates blank lines and malformed rows', () {
      final List<PulseSource> sources = parseSourcesShort(
        '\n\n0\n1\tgood.source\tdriver\n   \n',
      );

      expect(sources.map((PulseSource s) => s.name), <String>['good.source']);
    });

    test('empty output yields no sources', () {
      expect(parseSourcesShort(''), isEmpty);
    });
  });

  group('monitor resolution', () {
    test('appends .monitor to the default sink', () {
      expect(
        defaultSinkMonitor('alsa_output.pci-0000_00_1f.3.analog-stereo\n'),
        'alsa_output.pci-0000_00_1f.3.analog-stereo.monitor',
      );
    });

    test('does not double-suffix an already-monitor name', () {
      expect(defaultSinkMonitor('sink.monitor'), 'sink.monitor');
    });

    test('returns null when pactl reports nothing', () {
      expect(defaultSinkMonitor('   \n'), isNull);
      expect(defaultSinkMonitor(''), isNull);
    });
  });
}
