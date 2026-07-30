#ifndef FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_COM_UTILS_H_
#define FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_COM_UTILS_H_

// Small RAII wrappers for the COM and MMCSS resources the WASAPI paths hold.
//
// Control Center's plugin releases these by hand through a `cleanup` lambda per
// function. That is correct but has to be repeated at every early return, and
// this plugin has many more of them (prepare, capture, playback, enumeration).
// Scoped ownership makes the release order structural instead of a thing each
// new error path has to remember.

#include <windows.h>

#include <avrt.h>
#include <objbase.h>

#include <string>
#include <utility>

namespace audio_flutter_windows {

// Owns one COM interface pointer.
template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  ~ComPtr() { reset(); }

  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;

  ComPtr(ComPtr&& other) noexcept : ptr_(other.ptr_) { other.ptr_ = nullptr; }
  ComPtr& operator=(ComPtr&& other) noexcept {
    if (this != &other) {
      reset();
      ptr_ = other.ptr_;
      other.ptr_ = nullptr;
    }
    return *this;
  }

  // Address of the raw pointer, for COM out-parameters. Releases any previous
  // value first so a retried call cannot leak.
  T** put() {
    reset();
    return &ptr_;
  }

  T* get() const { return ptr_; }
  T* operator->() const { return ptr_; }
  explicit operator bool() const { return ptr_ != nullptr; }

  void reset() {
    if (ptr_ != nullptr) {
      ptr_->Release();
      ptr_ = nullptr;
    }
  }

 private:
  T* ptr_ = nullptr;
};

// Owns a block allocated by COM (GetMixFormat, IMMDevice::GetId, ...).
template <typename T>
class ComTaskMem {
 public:
  ComTaskMem() = default;
  ~ComTaskMem() { reset(); }

  ComTaskMem(const ComTaskMem&) = delete;
  ComTaskMem& operator=(const ComTaskMem&) = delete;

  T** put() {
    reset();
    return &ptr_;
  }

  T* get() const { return ptr_; }
  T* operator->() const { return ptr_; }
  explicit operator bool() const { return ptr_ != nullptr; }

  void reset() {
    if (ptr_ != nullptr) {
      ::CoTaskMemFree(ptr_);
      ptr_ = nullptr;
    }
  }

 private:
  T* ptr_ = nullptr;
};

// Initialises COM for the calling thread and uninitialises it only if this
// scope is the one that initialised it.
//
// RPC_E_CHANGED_MODE means the thread already has an apartment of a different
// kind. That is usable for everything here, but the balancing CoUninitialize
// belongs to whoever created it.
class ComApartment {
 public:
  ComApartment() {
    const HRESULT hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (SUCCEEDED(hr)) {
      owns_ = true;
      ok_ = true;
    } else if (hr == RPC_E_CHANGED_MODE) {
      ok_ = true;
    }
  }

  ~ComApartment() {
    if (owns_) {
      ::CoUninitialize();
    }
  }

  ComApartment(const ComApartment&) = delete;
  ComApartment& operator=(const ComApartment&) = delete;

  bool ok() const { return ok_; }

 private:
  bool owns_ = false;
  bool ok_ = false;
};

// Owns an MMCSS task registration.
class MmcssHandle {
 public:
  explicit MmcssHandle(HANDLE handle) : handle_(handle) {}

  ~MmcssHandle() {
    if (handle_ != nullptr) {
      ::AvRevertMmThreadCharacteristics(handle_);
    }
  }

  MmcssHandle(const MmcssHandle&) = delete;
  MmcssHandle& operator=(const MmcssHandle&) = delete;

 private:
  HANDLE handle_ = nullptr;
};

// UTF-16 -> UTF-8.
inline std::string Utf8FromWide(const wchar_t* wide) {
  if (wide == nullptr) {
    return std::string();
  }
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0,
                                         nullptr, nullptr);
  if (size <= 1) {
    return std::string();
  }
  std::string out(static_cast<size_t>(size - 1), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), size, nullptr,
                        nullptr);
  return out;
}

// UTF-8 -> UTF-16.
inline std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size =
      ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (size <= 1) {
    return std::wstring();
  }
  // `size` counts the terminator; size the string without it so c_str() is
  // terminated exactly once.
  std::wstring out(static_cast<size_t>(size - 1), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out.data(), size);
  return out;
}

}  // namespace audio_flutter_windows

#endif  // FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_COM_UTILS_H_
