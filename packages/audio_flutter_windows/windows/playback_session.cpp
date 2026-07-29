#include "playback_session.h"

// See capture_session.cpp for why this include order is deliberate.
// clang-format off
#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
// clang-format on

#include <algorithm>
#include <chrono>
#include <system_error>
#include <utility>

#include "audio_format.h"
#include "com_utils.h"

namespace audio_flutter_windows {

namespace {

constexpr REFERENCE_TIME kRefTimesPerSecond = 10000000;
constexpr REFERENCE_TIME kRequestedBufferDuration = kRefTimesPerSecond / 5;

}  // namespace

PlaybackSession::PlaybackSession(int64_t session_id, PlaybackConfig config,
                                 EventCallback on_event)
    : session_id_(session_id),
      config_(std::move(config)),
      on_event_(std::move(on_event)) {
  const int64_t channels = std::max(1, config_.channel_count);
  const int64_t buffered_samples =
      static_cast<int64_t>(config_.sample_rate) * channels *
      std::max<int64_t>(1, config_.max_buffered_duration_micros) / 1000000;
  max_queued_samples_ =
      static_cast<size_t>(std::max<int64_t>(channels, buffered_samples));
}

PlaybackSession::~PlaybackSession() {
  stop_requested_.store(true);
  data_available_.notify_all();
  space_available_.notify_all();
  JoinThread();
}

bool PlaybackSession::Prepare(std::string* error) {
  ComApartment apartment;
  if (!apartment.ok()) {
    if (error != nullptr) {
      *error = "COM could not be initialised on this thread";
    }
    return false;
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_ALL, IID_PPV_ARGS(enumerator.put()));
  if (FAILED(hr)) {
    if (error != nullptr) {
      *error = "MMDeviceEnumerator unavailable";
    }
    return false;
  }

  ComPtr<IMMDevice> device;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, device.put());
  if (FAILED(hr) || !device) {
    if (error != nullptr) {
      *error = "no render endpoint available";
    }
    return false;
  }

  Emit(SessionPhase::kPrepared);
  return true;
}

bool PlaybackSession::Start(std::string* error) {
  if (running_.load()) {
    return true;
  }
  stop_requested_.store(false);
  draining_.store(false);
  running_.store(true);
  Emit(SessionPhase::kStarting);
  try {
    thread_ = std::thread(&PlaybackSession::RenderThreadMain, this);
  } catch (const std::system_error&) {
    running_.store(false);
    if (error != nullptr) {
      *error = "render thread could not be started";
    }
    return false;
  }
  return true;
}

void PlaybackSession::Write(const std::vector<float>& samples) {
  if (samples.empty()) {
    return;
  }
  std::unique_lock<std::mutex> lock(mutex_);
  for (const float sample : samples) {
    space_available_.wait(lock, [this] {
      return queue_.size() < max_queued_samples_ || stop_requested_.load() ||
             !running_.load();
    });
    if (stop_requested_.load() || !running_.load()) {
      return;
    }
    queue_.push_back(sample);
  }
  data_available_.notify_all();
}

void PlaybackSession::Finish() {
  if (!running_.load() && !thread_.joinable()) {
    return;
  }
  Emit(SessionPhase::kStopping);
  draining_.store(true);
  data_available_.notify_all();
  JoinThread();
  running_.store(false);
  Emit(SessionPhase::kStopped);
}

void PlaybackSession::Abort() {
  stop_requested_.store(true);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.clear();
  }
  data_available_.notify_all();
  space_available_.notify_all();
  JoinThread();
  running_.store(false);
  Emit(SessionPhase::kStopped);
}

void PlaybackSession::JoinThread() {
  if (thread_.joinable()) {
    thread_.join();
  }
}

void PlaybackSession::Emit(SessionPhase phase, const std::string& code,
                           const std::string& message) {
  if (!on_event_) {
    return;
  }
  SessionEvent event;
  event.session_id = session_id_;
  event.phase = phase;
  event.code = code;
  event.message = message;
  on_event_(std::move(event));
}

void PlaybackSession::RenderThreadMain() {
  ComApartment apartment;
  if (!apartment.ok()) {
    running_.store(false);
    space_available_.notify_all();
    Emit(SessionPhase::kFailed, "PlaybackFailed",
         "COM could not be initialised on the render thread");
    return;
  }

  // Any early return past this point must wake a blocked Write; the lambda is
  // the single place that responsibility lives.
  const auto fail = [this](const char* code, const char* message) {
    running_.store(false);
    space_available_.notify_all();
    Emit(SessionPhase::kFailed, code, message);
  };

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_ALL, IID_PPV_ARGS(enumerator.put()));
  if (FAILED(hr)) {
    fail("PlaybackFailed", "MMDeviceEnumerator unavailable");
    return;
  }

  ComPtr<IMMDevice> device;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, device.put());
  if (FAILED(hr) || !device) {
    fail("PlaybackFailed", "no render endpoint available");
    return;
  }

  ComPtr<IAudioClient> audio_client;
  hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(audio_client.put()));
  if (FAILED(hr)) {
    fail("PlaybackFailed", "IAudioClient activation failed");
    return;
  }

  ComTaskMem<WAVEFORMATEX> mix_format;
  hr = audio_client->GetMixFormat(mix_format.put());
  if (FAILED(hr) || !mix_format) {
    fail("PlaybackFailed", "endpoint mix format unavailable");
    return;
  }

  hr = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                kRequestedBufferDuration, 0, mix_format.get(),
                                nullptr);
  if (FAILED(hr)) {
    fail("PlaybackFailed", "IAudioClient::Initialize failed");
    return;
  }

  UINT32 buffer_frame_count = 0;
  hr = audio_client->GetBufferSize(&buffer_frame_count);
  if (FAILED(hr)) {
    fail("PlaybackFailed", "buffer size unavailable");
    return;
  }

  ComPtr<IAudioRenderClient> render_client;
  hr = audio_client->GetService(__uuidof(IAudioRenderClient),
                                reinterpret_cast<void**>(render_client.put()));
  if (FAILED(hr) || !render_client) {
    fail("PlaybackFailed", "IAudioRenderClient unavailable");
    return;
  }

  const WORD dest_channels = mix_format->nChannels;
  const WORD dest_bits = mix_format->wBitsPerSample;
  const DWORD dest_rate = mix_format->nSamplesPerSec;
  const bool dest_is_float = IsFloatFormat(mix_format.get());
  const bool dest_is_pcm = IsPcmFormat(mix_format.get());
  if ((!dest_is_float && !dest_is_pcm) || dest_channels == 0 ||
      dest_bits == 0 || dest_rate == 0) {
    fail("PlaybackFailed", "endpoint mix format cannot be interpreted");
    return;
  }

  const auto source_channels =
      static_cast<size_t>(std::max(1, config_.channel_count));
  LinearResampler resampler;
  resampler.Reset(static_cast<double>(config_.sample_rate),
                  static_cast<double>(dest_rate));

  DWORD mmcss_task_index = 0;
  MmcssHandle mmcss(
      ::AvSetMmThreadCharacteristicsW(L"Pro Audio", &mmcss_task_index));

  const double buffer_seconds = static_cast<double>(buffer_frame_count) /
                                static_cast<double>(dest_rate);
  DWORD sleep_ms = static_cast<DWORD>(buffer_seconds * 1000.0 / 2.0);
  sleep_ms = std::max<DWORD>(5, std::min<DWORD>(50, sleep_ms));

  hr = audio_client->Start();
  if (FAILED(hr)) {
    fail("PlaybackFailed", "IAudioClient::Start failed");
    return;
  }

  Emit(SessionPhase::kRunning);

  std::vector<float> mono_in;
  std::vector<float> resampled;

  while (!stop_requested_.load()) {
    UINT32 padding = 0;
    hr = audio_client->GetCurrentPadding(&padding);
    if (FAILED(hr)) {
      break;
    }
    const UINT32 writable = buffer_frame_count - padding;

    if (writable > 0) {
      // Pull enough source samples to fill `writable` destination frames.
      const auto wanted = static_cast<size_t>(
          static_cast<double>(writable) *
              (static_cast<double>(config_.sample_rate) /
               static_cast<double>(dest_rate)) +
          2.0);

      mono_in.clear();
      {
        std::unique_lock<std::mutex> lock(mutex_);
        if (queue_.empty() && !draining_.load() && !stop_requested_.load()) {
          data_available_.wait_for(lock, std::chrono::milliseconds(sleep_ms),
                                   [this] {
                                     return !queue_.empty() ||
                                            draining_.load() ||
                                            stop_requested_.load();
                                   });
        }
        const size_t available = queue_.size() / source_channels;
        const size_t take = std::min(wanted, available);
        for (size_t index = 0; index < take; ++index) {
          // Down-mix the interleaved source frame to one mono sample.
          double sum = 0.0;
          for (size_t channel = 0; channel < source_channels; ++channel) {
            sum += queue_.front();
            queue_.pop_front();
          }
          mono_in.push_back(
              static_cast<float>(sum / static_cast<double>(source_channels)));
        }
      }
      space_available_.notify_all();

      if (mono_in.empty() && draining_.load()) {
        break;  // Queue drained and no more input is coming.
      }

      if (!mono_in.empty()) {
        resampled.clear();
        resampler.Process(mono_in, &resampled);

        if (!resampled.empty()) {
          const auto frames = static_cast<UINT32>(
              std::min<size_t>(resampled.size(), writable));
          BYTE* buffer = nullptr;
          hr = render_client->GetBuffer(frames, &buffer);
          if (FAILED(hr)) {
            break;
          }
          for (UINT32 frame = 0; frame < frames; ++frame) {
            WriteMonoSample(buffer, frame, dest_channels, dest_bits,
                            dest_is_float, resampled[frame]);
          }
          hr = render_client->ReleaseBuffer(frames, 0);
          if (FAILED(hr)) {
            break;
          }
        }
      }
    }

    DWORD slept = 0;
    while (slept < sleep_ms && !stop_requested_.load()) {
      const DWORD chunk = std::min<DWORD>(5, sleep_ms - slept);
      ::Sleep(chunk);
      slept += chunk;
    }
  }

  audio_client->Stop();
  running_.store(false);
  // A Write blocked on a full queue must not outlive the render thread.
  space_available_.notify_all();

  if (FAILED(hr) && !stop_requested_.load() && !draining_.load()) {
    Emit(SessionPhase::kFailed, "PlaybackFailed",
         "the WASAPI render loop failed");
  }
}

}  // namespace audio_flutter_windows
