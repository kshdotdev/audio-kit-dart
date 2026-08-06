#ifndef FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PROCESS_LOOPBACK_CAPTURE_H_
#define FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PROCESS_LOOPBACK_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace audio_flutter_windows {

/// Minimum Windows build documented for application-loopback activation.
constexpr DWORD kMinimumProcessLoopbackBuild = 20348;

/// One render-session owner visible to application capture selection.
struct AudioProcessInfo {
  DWORD process_id = 0;
  std::string application_id;
  bool is_producing_audio = false;
};

/// True only when the running OS supports documented process-loopback APIs.
bool IsProcessLoopbackSupported();

/// Enumerates local processes that currently own a WASAPI render session.
std::vector<AudioProcessInfo> ListAudioRenderProcesses();

/// Poll-driven capture of the union of one or more Windows process trees.
///
/// Windows activates one process tree per IAudioClient. This adapter creates a
/// client for every independent requested root, aligns them on the shared QPC
/// clock, and mixes only samples present in every client. It never substitutes
/// endpoint loopback, so a failed activation cannot broaden the source.
class ProcessLoopbackCapture {
 public:
  ProcessLoopbackCapture(std::vector<DWORD> process_ids, int sample_rate,
                         int channel_count);
  ~ProcessLoopbackCapture();

  ProcessLoopbackCapture(const ProcessLoopbackCapture&) = delete;
  ProcessLoopbackCapture& operator=(const ProcessLoopbackCapture&) = delete;

  bool Initialize(std::string* error);
  bool Start(std::string* error);
  void Stop();

  /// Drains available packets and appends their aligned, clipped mix.
  ///
  /// [timestamp_micros] is the QPC-derived timestamp of the first appended
  /// sample frame. It is meaningful only when [samples] is non-empty.
  bool Drain(std::vector<float>* samples, int64_t* timestamp_micros,
             std::string* error);

  const std::vector<DWORD>& process_ids() const { return process_ids_; }

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  std::vector<DWORD> process_ids_;
  int sample_rate_;
  int channel_count_;
};

}  // namespace audio_flutter_windows

#endif  // FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PROCESS_LOOPBACK_CAPTURE_H_
