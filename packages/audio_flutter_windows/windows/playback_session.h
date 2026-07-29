#ifndef FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PLAYBACK_SESSION_H_
#define FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PLAYBACK_SESSION_H_

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "capture_session.h"  // SessionPhase, SessionEvent, EventCallback

namespace audio_flutter_windows {

struct PlaybackConfig {
  int sample_rate = 16000;
  int channel_count = 1;
  int64_t max_buffered_duration_micros = 2000000;
};

// One WASAPI render stream fed by writePlaybackFrames.
//
// Written samples queue in a bounded buffer that a render thread drains into
// the endpoint. `Write` blocks while the queue is full, which is what applies
// backpressure to the Dart caller; `Finish` drains what is queued before
// stopping, `Abort` discards it.
class PlaybackSession {
 public:
  PlaybackSession(int64_t session_id, PlaybackConfig config,
                  EventCallback on_event);
  ~PlaybackSession();

  PlaybackSession(const PlaybackSession&) = delete;
  PlaybackSession& operator=(const PlaybackSession&) = delete;

  int64_t session_id() const { return session_id_; }
  const PlaybackConfig& config() const { return config_; }

  bool Prepare(std::string* error);
  bool Start(std::string* error);

  // Appends interleaved float32 samples, waiting while the queue is full.
  void Write(const std::vector<float>& samples);

  // Stops once the queue has drained.
  void Finish();

  // Stops immediately, discarding queued samples.
  void Abort();

 private:
  void RenderThreadMain();
  void JoinThread();
  void Emit(SessionPhase phase, const std::string& code = std::string(),
            const std::string& message = std::string());

  const int64_t session_id_;
  const PlaybackConfig config_;
  const EventCallback on_event_;

  size_t max_queued_samples_ = 0;

  std::thread thread_;
  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> draining_{false};
  std::atomic<bool> running_{false};

  std::mutex mutex_;
  std::condition_variable space_available_;
  std::condition_variable data_available_;
  std::deque<float> queue_;
};

}  // namespace audio_flutter_windows

#endif  // FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PLAYBACK_SESSION_H_
