import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Output of a short-lived command such as `pactl list sources short`.
final class LinuxProcessResult {
  const LinuxProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// A spawned child process owned by one capture or playback session.
///
/// [stderr] must always be drained by the owner: an unread pipe fills its
/// kernel buffer and blocks the child, which manifests as a capture that
/// simply stops delivering audio.
abstract interface class LinuxProcessHandle {
  Stream<List<int>> get stdout;

  Stream<List<int>> get stderr;

  Future<int> get exitCode;

  /// Writes to the child's stdin and awaits the flush, so the returned future
  /// is the backpressure signal for a playback writer.
  Future<void> writeStdin(List<int> data);

  Future<void> closeStdin();

  bool kill();
}

/// Seam over process discovery and spawning.
///
/// Every command this package issues goes through this interface so the whole
/// implementation is exercisable on a host without PulseAudio or PipeWire.
abstract interface class LinuxProcessRunner {
  /// Whether [executable] resolves on `PATH`.
  Future<bool> exists(String executable);

  Future<LinuxProcessResult> run(String executable, List<String> arguments);

  Future<LinuxProcessHandle> start(String executable, List<String> arguments);
}

/// Default runner backed by `dart:io`.
final class SystemLinuxProcessRunner implements LinuxProcessRunner {
  const SystemLinuxProcessRunner();

  @override
  Future<bool> exists(String executable) async {
    try {
      final ProcessResult result = await Process.run('which', <String>[
        executable,
      ]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<LinuxProcessResult> run(
    String executable,
    List<String> arguments,
  ) async {
    final ProcessResult result = await Process.run(
      executable,
      arguments,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return LinuxProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String? ?? '',
      stderr: result.stderr as String? ?? '',
    );
  }

  @override
  Future<LinuxProcessHandle> start(
    String executable,
    List<String> arguments,
  ) async {
    final Process process = await Process.start(executable, arguments);
    return _SystemLinuxProcessHandle(process);
  }
}

final class _SystemLinuxProcessHandle implements LinuxProcessHandle {
  _SystemLinuxProcessHandle(this._process);

  final Process _process;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<void> writeStdin(List<int> data) async {
    _process.stdin.add(data);
    await _process.stdin.flush();
  }

  @override
  Future<void> closeStdin() async {
    await _process.stdin.close();
  }

  @override
  bool kill() => _process.kill();
}
