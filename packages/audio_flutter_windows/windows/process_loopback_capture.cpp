#include "process_loopback_capture.h"

// Order matters. mmdeviceapi supplies the async activation interfaces and
// audiopolicy supplies render-session enumeration.
#include <audioclient.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <tlhelp32.h>

#if __has_include(<audioclientactivationparams.h>)
#include <audioclientactivationparams.h>
#else
// MinGW's headers can lag the Windows SDK. These ABI definitions let the
// source undergo cross-compiler syntax validation; MSVC uses the SDK header.
typedef enum AUDIOCLIENT_ACTIVATION_TYPE {
  AUDIOCLIENT_ACTIVATION_TYPE_DEFAULT,
  AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
} AUDIOCLIENT_ACTIVATION_TYPE;
typedef enum PROCESS_LOOPBACK_MODE {
  PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
  PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE
} PROCESS_LOOPBACK_MODE;
typedef struct AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
  DWORD TargetProcessId;
  PROCESS_LOOPBACK_MODE ProcessLoopbackMode;
} AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS;
typedef struct AUDIOCLIENT_ACTIVATION_PARAMS {
  AUDIOCLIENT_ACTIVATION_TYPE ActivationType;
  union {
    AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
  };
} AUDIOCLIENT_ACTIVATION_PARAMS;
#ifndef VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK
#define VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK L"VAD\\Process_Loopback"
#endif
#endif

#include <algorithm>
#include <atomic>
#include <map>
#include <set>
#include <sstream>
#include <utility>

#include "com_utils.h"

namespace audio_flutter_windows {
namespace {

constexpr int64_t kHundredNanosecondsPerSecond = 10000000;
constexpr size_t kMaximumPendingSeconds = 3;

DWORD CurrentWindowsBuild() {
  using RtlGetVersionFunction = LONG(WINAPI*)(OSVERSIONINFOW*);
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) {
    return 0;
  }
  const auto rtl_get_version = reinterpret_cast<RtlGetVersionFunction>(
      ::GetProcAddress(ntdll, "RtlGetVersion"));
  if (rtl_get_version == nullptr) {
    return 0;
  }
  OSVERSIONINFOW version = {};
  version.dwOSVersionInfoSize = sizeof(version);
  return rtl_get_version(&version) == 0 ? version.dwBuildNumber : 0;
}

int64_t QpcNowHundredNanoseconds() {
  LARGE_INTEGER counter = {};
  LARGE_INTEGER frequency = {};
  if (!::QueryPerformanceCounter(&counter) ||
      !::QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) {
    return 0;
  }
  const long double scaled =
      static_cast<long double>(counter.QuadPart) *
      static_cast<long double>(kHundredNanosecondsPerSecond) /
      static_cast<long double>(frequency.QuadPart);
  return static_cast<int64_t>(scaled);
}

std::string ProcessApplicationId(DWORD process_id,
                                 const std::string& fallback) {
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                 process_id);
  if (process == nullptr) {
    return fallback;
  }
  std::wstring path(32768, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  const BOOL queried =
      ::QueryFullProcessImageNameW(process, 0, path.data(), &size);
  ::CloseHandle(process);
  if (!queried || size == 0) {
    return fallback;
  }
  path.resize(size);
  const size_t separator = path.find_last_of(L"\\/");
  const std::wstring name =
      separator == std::wstring::npos ? path : path.substr(separator + 1);
  const std::string utf8 = Utf8FromWide(name.c_str());
  return utf8.empty() ? fallback : utf8;
}

std::vector<DWORD> IndependentProcessRoots(
    const std::vector<DWORD>& process_ids) {
  const std::set<DWORD> selected(process_ids.begin(), process_ids.end());
  std::map<DWORD, DWORD> parents;
  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot != INVALID_HANDLE_VALUE) {
    PROCESSENTRY32W entry = {};
    entry.dwSize = sizeof(entry);
    if (::Process32FirstW(snapshot, &entry)) {
      do {
        parents[entry.th32ProcessID] = entry.th32ParentProcessID;
      } while (::Process32NextW(snapshot, &entry));
    }
    ::CloseHandle(snapshot);
  }

  std::vector<DWORD> roots;
  for (const DWORD process_id : selected) {
    bool covered_by_selected_ancestor = false;
    DWORD cursor = process_id;
    std::set<DWORD> visited;
    while (visited.insert(cursor).second) {
      const auto parent = parents.find(cursor);
      if (parent == parents.end() || parent->second == 0 ||
          parent->second == cursor) {
        break;
      }
      cursor = parent->second;
      if (selected.count(cursor) != 0) {
        covered_by_selected_ancestor = true;
        break;
      }
    }
    if (!covered_by_selected_ancestor) {
      roots.push_back(process_id);
    }
  }
  return roots;
}

class ActivationHandler final
    : public IActivateAudioInterfaceCompletionHandler {
 public:
  ActivationHandler()
      : completed_(::CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    *object = nullptr;
    if (::IsEqualIID(iid, __uuidof(IUnknown)) ||
        ::IsEqualIID(
            iid, __uuidof(IActivateAudioInterfaceCompletionHandler)) ||
        ::IsEqualIID(iid, __uuidof(IAgileObject))) {
      *object = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG references = --references_;
    if (references == 0) {
      delete this;
    }
    return references;
  }

  HRESULT STDMETHODCALLTYPE ActivateCompleted(
      IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT activation_result = E_UNEXPECTED;
    ComPtr<IUnknown> activated;
    HRESULT hr = operation == nullptr
                     ? E_POINTER
                     : operation->GetActivateResult(&activation_result,
                                                    activated.put());
    if (SUCCEEDED(hr)) {
      hr = activation_result;
    }
    if (SUCCEEDED(hr) && activated) {
      hr = activated->QueryInterface(__uuidof(IAudioClient),
                                     reinterpret_cast<void**>(client_.put()));
    }
    result_ = hr;
    if (completed_ != nullptr) {
      ::SetEvent(completed_);
    }
    return S_OK;
  }

  bool WaitForClient(ComPtr<IAudioClient>* client, std::string* error) {
    if (completed_ == nullptr ||
        ::WaitForSingleObject(completed_, 10000) != WAIT_OBJECT_0) {
      if (error != nullptr) {
        *error = "process-loopback activation timed out";
      }
      return false;
    }
    if (FAILED(result_) || !client_) {
      if (error != nullptr) {
        std::ostringstream message;
        message << "process-loopback activation failed (HRESULT 0x" << std::hex
                << static_cast<unsigned long>(result_) << ')';
        *error = message.str();
      }
      return false;
    }
    const HRESULT hr = client_->QueryInterface(
        __uuidof(IAudioClient), reinterpret_cast<void**>(client->put()));
    if (FAILED(hr)) {
      if (error != nullptr) {
        *error = "activated process loopback did not return IAudioClient";
      }
      return false;
    }
    return true;
  }

 private:
  ~ActivationHandler() {
    if (completed_ != nullptr) {
      ::CloseHandle(completed_);
    }
  }

  std::atomic<ULONG> references_{1};
  HANDLE completed_ = nullptr;
  HRESULT result_ = E_PENDING;
  ComPtr<IAudioClient> client_;
};

bool ActivateProcessClient(DWORD process_id, ComPtr<IAudioClient>* client,
                           std::string* error) {
  AUDIOCLIENT_ACTIVATION_PARAMS activation = {};
  activation.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  activation.ProcessLoopbackParams.TargetProcessId = process_id;
  activation.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;

  PROPVARIANT parameters;
  ::PropVariantInit(&parameters);
  parameters.vt = VT_BLOB;
  parameters.blob.cbSize = sizeof(activation);
  parameters.blob.pBlobData = reinterpret_cast<BYTE*>(&activation);

  ActivationHandler* handler = new ActivationHandler();
  ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  const HRESULT hr = ::ActivateAudioInterfaceAsync(
      VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
      &parameters, handler, operation.put());
  if (FAILED(hr)) {
    handler->Release();
    if (error != nullptr) {
      std::ostringstream message;
      message << "ActivateAudioInterfaceAsync failed for process "
              << process_id << " (HRESULT 0x" << std::hex
              << static_cast<unsigned long>(hr) << ')';
      *error = message.str();
    }
    return false;
  }
  const bool completed = handler->WaitForClient(client, error);
  handler->Release();
  return completed;
}

}  // namespace

struct ProcessLoopbackCapture::Impl {
  struct Client {
    DWORD process_id = 0;
    ComPtr<IAudioClient> audio_client;
    ComPtr<IAudioCaptureClient> capture_client;
    std::vector<float> pending;
    int64_t first_qpc_hns = 0;
  };

  std::vector<Client> clients;
  int64_t anchor_qpc_hns = 0;
  int64_t emitted_sample_frames = 0;
  bool alignment_ready = false;
  bool started = false;
};

bool IsProcessLoopbackSupported() {
  return CurrentWindowsBuild() >= kMinimumProcessLoopbackBuild;
}

std::vector<AudioProcessInfo> ListAudioRenderProcesses() {
  std::map<DWORD, AudioProcessInfo> by_process;
  if (!IsProcessLoopbackSupported()) {
    return {};
  }
  ComApartment apartment;
  if (!apartment.ok()) {
    return {};
  }

  ComPtr<IMMDeviceEnumerator> device_enumerator;
  if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL,
                                IID_PPV_ARGS(device_enumerator.put())))) {
    return {};
  }
  ComPtr<IMMDeviceCollection> devices;
  if (FAILED(device_enumerator->EnumAudioEndpoints(
          eRender, DEVICE_STATE_ACTIVE, devices.put())) ||
      !devices) {
    return {};
  }

  UINT device_count = 0;
  devices->GetCount(&device_count);
  for (UINT device_index = 0; device_index < device_count; ++device_index) {
    ComPtr<IMMDevice> device;
    if (FAILED(devices->Item(device_index, device.put())) || !device) {
      continue;
    }
    ComPtr<IAudioSessionManager2> manager;
    if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL,
                                nullptr,
                                reinterpret_cast<void**>(manager.put()))) ||
        !manager) {
      continue;
    }
    ComPtr<IAudioSessionEnumerator> sessions;
    if (FAILED(manager->GetSessionEnumerator(sessions.put())) || !sessions) {
      continue;
    }
    int session_count = 0;
    sessions->GetCount(&session_count);
    for (int session_index = 0; session_index < session_count;
         ++session_index) {
      ComPtr<IAudioSessionControl> control;
      if (FAILED(sessions->GetSession(session_index, control.put())) ||
          !control) {
        continue;
      }
      ComPtr<IAudioSessionControl2> control2;
      if (FAILED(control->QueryInterface(
              __uuidof(IAudioSessionControl2),
              reinterpret_cast<void**>(control2.put()))) ||
          !control2) {
        continue;
      }
      DWORD process_id = 0;
      if (FAILED(control2->GetProcessId(&process_id)) || process_id == 0 ||
          process_id == ::GetCurrentProcessId()) {
        continue;
      }

      AudioSessionState state = AudioSessionStateInactive;
      control->GetState(&state);
      std::string fallback;
      LPWSTR display_name = nullptr;
      if (SUCCEEDED(control->GetDisplayName(&display_name)) &&
          display_name != nullptr) {
        fallback = Utf8FromWide(display_name);
        ::CoTaskMemFree(display_name);
      }
      if (fallback.empty()) {
        fallback = "process-" + std::to_string(process_id);
      }

      auto entry = by_process.emplace(
          process_id,
          AudioProcessInfo{process_id,
                           ProcessApplicationId(process_id, fallback), false})
                       .first;
      entry->second.is_producing_audio = entry->second.is_producing_audio ||
                                         state == AudioSessionStateActive;
    }
  }

  std::vector<AudioProcessInfo> result;
  result.reserve(by_process.size());
  for (auto& [process_id, info] : by_process) {
    result.push_back(std::move(info));
  }
  return result;
}

ProcessLoopbackCapture::ProcessLoopbackCapture(std::vector<DWORD> process_ids,
                                               int sample_rate,
                                               int channel_count)
    : impl_(std::make_unique<Impl>()),
      // Preserve the exact normalized request for diagnostics and manifests.
      // Redundant roots are collapsed only at native activation time below.
      process_ids_(std::move(process_ids)),
      sample_rate_(sample_rate),
      channel_count_(channel_count) {}

ProcessLoopbackCapture::~ProcessLoopbackCapture() { Stop(); }

bool ProcessLoopbackCapture::Initialize(std::string* error) {
  if (!IsProcessLoopbackSupported()) {
    if (error != nullptr) {
      *error = "process loopback requires Windows OS build 20348 or newer";
    }
    return false;
  }
  if (process_ids_.empty() || sample_rate_ <= 0 || channel_count_ <= 0) {
    if (error != nullptr) {
      *error =
          "process loopback requires at least one process and a valid format";
    }
    return false;
  }

  WAVEFORMATEX format = {};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = static_cast<WORD>(channel_count_);
  format.nSamplesPerSec = static_cast<DWORD>(sample_rate_);
  format.wBitsPerSample = 16;
  format.nBlockAlign = static_cast<WORD>(format.nChannels * sizeof(int16_t));
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;

  const std::vector<DWORD> activation_roots =
      IndependentProcessRoots(process_ids_);
  for (const DWORD process_id : activation_roots) {
    Impl::Client client;
    client.process_id = process_id;
    if (!ActivateProcessClient(process_id, &client.audio_client, error)) {
      return false;
    }
    const DWORD flags = AUDCLNT_STREAMFLAGS_LOOPBACK |
                        AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                        AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    const HRESULT initialize = client.audio_client->Initialize(
        AUDCLNT_SHAREMODE_SHARED, flags, 0, 0, &format, nullptr);
    if (FAILED(initialize)) {
      if (error != nullptr) {
        std::ostringstream message;
        message << "process loopback Initialize failed for process "
                << process_id << " (HRESULT 0x" << std::hex
                << static_cast<unsigned long>(initialize) << ')';
        *error = message.str();
      }
      return false;
    }
    if (FAILED(client.audio_client->GetService(
            __uuidof(IAudioCaptureClient),
            reinterpret_cast<void**>(client.capture_client.put()))) ||
        !client.capture_client) {
      if (error != nullptr) {
        *error = "IAudioCaptureClient unavailable for process loopback";
      }
      return false;
    }
    impl_->clients.push_back(std::move(client));
  }
  return true;
}

bool ProcessLoopbackCapture::Start(std::string* error) {
  impl_->started = true;
  for (Impl::Client& client : impl_->clients) {
    const HRESULT hr = client.audio_client->Start();
    if (FAILED(hr)) {
      Stop();
      if (error != nullptr) {
        *error = "process-loopback IAudioClient::Start failed";
      }
      return false;
    }
  }
  return true;
}

void ProcessLoopbackCapture::Stop() {
  if (!impl_ || !impl_->started) {
    return;
  }
  for (Impl::Client& client : impl_->clients) {
    client.audio_client->Stop();
  }
  impl_->started = false;
}

bool ProcessLoopbackCapture::Drain(std::vector<float>* samples,
                                   int64_t* timestamp_micros,
                                   std::string* error) {
  if (samples == nullptr || timestamp_micros == nullptr) {
    if (error != nullptr) {
      *error = "process-loopback drain received a null output";
    }
    return false;
  }
  samples->clear();

  for (Impl::Client& client : impl_->clients) {
    UINT32 packet_frames = 0;
    HRESULT hr = client.capture_client->GetNextPacketSize(&packet_frames);
    while (SUCCEEDED(hr) && packet_frames > 0) {
      BYTE* data = nullptr;
      DWORD flags = 0;
      UINT64 qpc_position = 0;
      hr = client.capture_client->GetBuffer(&data, &packet_frames, &flags,
                                            nullptr, &qpc_position);
      if (FAILED(hr)) {
        break;
      }
      if (client.first_qpc_hns == 0) {
        client.first_qpc_hns =
            (flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) == 0 &&
                    qpc_position != 0
                ? static_cast<int64_t>(qpc_position)
                : QpcNowHundredNanoseconds();
      }
      const size_t sample_count =
          static_cast<size_t>(packet_frames) * channel_count_;
      const size_t original_size = client.pending.size();
      client.pending.resize(original_size + sample_count, 0.0f);
      if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0 && data != nullptr) {
        const auto* pcm = reinterpret_cast<const int16_t*>(data);
        for (size_t index = 0; index < sample_count; ++index) {
          client.pending[original_size + index] =
              static_cast<float>(pcm[index]) / 32768.0f;
        }
      }
      hr = client.capture_client->ReleaseBuffer(packet_frames);
      if (FAILED(hr)) {
        break;
      }
      hr = client.capture_client->GetNextPacketSize(&packet_frames);
    }
    if (FAILED(hr)) {
      if (error != nullptr) {
        *error = "process-loopback packet read failed";
      }
      return false;
    }
  }

  if (!impl_->alignment_ready) {
    if (std::any_of(impl_->clients.begin(), impl_->clients.end(),
                    [](const Impl::Client& client) {
                      return client.first_qpc_hns == 0;
                    })) {
      return true;
    }
    impl_->anchor_qpc_hns = std::min_element(
                                impl_->clients.begin(), impl_->clients.end(),
                                [](const Impl::Client& left,
                                   const Impl::Client& right) {
                                  return left.first_qpc_hns <
                                         right.first_qpc_hns;
                                })
                                ->first_qpc_hns;
    for (Impl::Client& client : impl_->clients) {
      const int64_t delta_hns =
          std::max<int64_t>(0, client.first_qpc_hns - impl_->anchor_qpc_hns);
      const size_t leading_frames = static_cast<size_t>(
          delta_hns * sample_rate_ / kHundredNanosecondsPerSecond);
      client.pending.insert(client.pending.begin(),
                            leading_frames * channel_count_, 0.0f);
    }
    impl_->alignment_ready = true;
  }

  size_t common_samples = impl_->clients.front().pending.size();
  for (const Impl::Client& client : impl_->clients) {
    common_samples = std::min(common_samples, client.pending.size());
  }
  common_samples -= common_samples % static_cast<size_t>(channel_count_);
  if (common_samples == 0) {
    const size_t maximum_pending = static_cast<size_t>(sample_rate_) *
                                   channel_count_ * kMaximumPendingSeconds;
    if (std::any_of(impl_->clients.begin(), impl_->clients.end(),
                    [maximum_pending](const Impl::Client& client) {
                      return client.pending.size() > maximum_pending;
                    })) {
      if (error != nullptr) {
        *error = "one process-loopback client stopped advancing its clock";
      }
      return false;
    }
    return true;
  }

  samples->assign(common_samples, 0.0f);
  for (Impl::Client& client : impl_->clients) {
    for (size_t index = 0; index < common_samples; ++index) {
      (*samples)[index] += client.pending[index];
    }
    client.pending.erase(
        client.pending.begin(),
        client.pending.begin() + static_cast<std::ptrdiff_t>(common_samples));
  }
  for (float& sample : *samples) {
    sample = std::max(-1.0f, std::min(1.0f, sample));
  }

  *timestamp_micros = impl_->anchor_qpc_hns / 10 +
                      impl_->emitted_sample_frames * 1000000 /
                          std::max(1, sample_rate_);
  impl_->emitted_sample_frames +=
      static_cast<int64_t>(common_samples / channel_count_);
  return true;
}

}  // namespace audio_flutter_windows
