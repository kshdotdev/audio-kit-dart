import 'dart:async';
import 'dart:typed_data';

import 'package:audio_flutter_linux/audio_flutter_linux.dart';
import 'package:audio_flutter_platform_interface/audio_flutter_platform_interface.dart';

/// Scripted stand-in for a spawned `parecord`/`paplay` child.
final class FakeProcessHandle implements LinuxProcessHandle {
  FakeProcessHandle(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;

  final StreamController<List<int>> stdoutController =
      StreamController<List<int>>();
  final StreamController<List<int>> stderrController =
      StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  final BytesBuilder stdinWrites = BytesBuilder(copy: true);

  bool stdinClosed = false;
  bool killed = false;

  @override
  Stream<List<int>> get stdout => stdoutController.stream;

  @override
  Stream<List<int>> get stderr => stderrController.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> writeStdin(List<int> data) async => stdinWrites.add(data);

  @override
  Future<void> closeStdin() async => stdinClosed = true;

  @override
  bool kill() {
    killed = true;
    complete(-9);
    return true;
  }

  /// Terminates the fake child, closing stdout the way a real exit does.
  void complete(int code) {
    if (!_exit.isCompleted) {
      _exit.complete(code);
    }
    if (!stdoutController.isClosed) {
      unawaited(stdoutController.close());
    }
    if (!stderrController.isClosed) {
      unawaited(stderrController.close());
    }
  }
}

/// Process seam that records every command and never touches the host.
final class FakeProcessRunner implements LinuxProcessRunner {
  FakeProcessRunner({
    Set<String>? installed,
    Map<String, LinuxProcessResult>? commandResults,
    Set<String>? unstartable,
  }) : installed = installed ?? <String>{},
       commandResults = commandResults ?? <String, LinuxProcessResult>{},
       unstartable = unstartable ?? <String>{};

  /// Executables `which` resolves.
  final Set<String> installed;

  /// Canned `run` output, keyed by `'executable arg arg'`.
  final Map<String, LinuxProcessResult> commandResults;

  /// Executables whose `start` throws, exercising the fallback chain.
  final Set<String> unstartable;

  final List<List<String>> startedCommands = <List<String>>[];
  final List<List<String>> ranCommands = <List<String>>[];
  final List<FakeProcessHandle> handles = <FakeProcessHandle>[];

  FakeProcessHandle get lastHandle => handles.last;

  @override
  Future<bool> exists(String executable) async =>
      installed.contains(executable);

  @override
  Future<LinuxProcessResult> run(
    String executable,
    List<String> arguments,
  ) async {
    ranCommands.add(<String>[executable, ...arguments]);
    return commandResults['$executable ${arguments.join(' ')}'] ??
        const LinuxProcessResult(exitCode: 1, stdout: '', stderr: '');
  }

  @override
  Future<LinuxProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async {
    if (unstartable.contains(executable)) {
      throw ProcessStartFailure(executable);
    }
    startedCommands.add(<String>[executable, ...arguments]);
    final FakeProcessHandle handle = FakeProcessHandle(executable, arguments);
    handles.add(handle);
    return handle;
  }
}

/// Raised by [FakeProcessRunner] for executables marked unstartable.
final class ProcessStartFailure implements Exception {
  const ProcessStartFailure(this.executable);

  final String executable;

  @override
  String toString() => 'ProcessStartFailure($executable)';
}

/// In-memory recording sink so `rawRecordingPath` is testable without disk.
final class FakeRecordingSink implements LinuxRecordingSink {
  FakeRecordingSink(this.path, this.format);

  final String path;
  final PlatformPcmFormat format;
  final BytesBuilder written = BytesBuilder(copy: true);

  bool opened = false;
  bool closed = false;
  bool aborted = false;

  @override
  Future<void> open() async => opened = true;

  @override
  void add(List<int> pcm16) => written.add(pcm16);

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> abort() async {
    aborted = true;
    closed = true;
  }
}

/// Builds `count` interleaved signed 16-bit samples with a recognizable ramp.
Uint8List pcm16Ramp(int count, {int start = 0}) {
  final Uint8List bytes = Uint8List(count * 2);
  final ByteData data = ByteData.sublistView(bytes);
  for (var index = 0; index < count; index++) {
    data.setInt16(index * 2, start + index, Endian.little);
  }
  return bytes;
}

/// Canned `pactl list sources short` output with two inputs and two monitors.
const String kPactlSourcesShort = '''
0\talsa_output.pci-0000_00_1f.3.analog-stereo.monitor\tPipeWire\ts16le 2ch 48000Hz\tIDLE
1\talsa_input.pci-0000_00_1f.3.analog-stereo\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED
2\talsa_output.usb-Focusrite.analog-stereo.monitor\tPipeWire\ts16le 2ch 48000Hz\tIDLE
3\tbluez_input.AC_12_2F.headset\tPipeWire\ts16le 1ch 16000Hz\tRUNNING
''';
