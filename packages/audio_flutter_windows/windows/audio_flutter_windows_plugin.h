#ifndef FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <windows.h>

#include <mmdeviceapi.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <string>

#include "capture_session.h"
#include "playback_session.h"

namespace audio_flutter_windows {

// WASAPI implementation of the audio_flutter platform contract.
//
// Capture sessions push converted frames into their own bounded ring; Dart
// drains them with `readCaptureFrames`. Only lifecycle events travel over the
// event channel, so the platform-thread task queue below carries a handful of
// messages per session rather than every audio frame.
class AudioFlutterWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit AudioFlutterWindowsPlugin(
      flutter::PluginRegistrarWindows* registrar);
  ~AudioFlutterWindowsPlugin() override;

  AudioFlutterWindowsPlugin(const AudioFlutterWindowsPlugin&) = delete;
  AudioFlutterWindowsPlugin& operator=(const AudioFlutterWindowsPlugin&) =
      delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Capture.
  void PrepareCapture(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void ReadCaptureFrames(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Playback.
  void PreparePlayback(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void WritePlaybackFrames(
      const flutter::EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Enumeration. `flow` selects capture (inputs) or render (system sources).
  flutter::EncodableValue ListEndpoints(EDataFlow flow);

  // Borrowed for the duration of one method call. Safe because every method
  // call arrives on the platform thread, so a dispose cannot interleave with a
  // call that is still using the session.
  CaptureSession* FindCapture(const flutter::EncodableMap& arguments);
  PlaybackSession* FindPlayback(const flutter::EncodableMap& arguments);

  // Delivers a session event to Dart. Safe to call from any thread: the event
  // is queued and drained on the platform thread, because the Flutter event
  // sink is not thread-safe.
  void PostEvent(SessionEvent event);
  void DrainPlatformTasks();
  void RunOnPlatformThread(std::function<void()> task);

  flutter::PluginRegistrarWindows* registrar_ = nullptr;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;

  // Touched exclusively on the platform thread.
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  int window_proc_id_ = -1;

  std::mutex tasks_mutex_;
  std::queue<std::function<void()>> tasks_;

  std::mutex sessions_mutex_;
  std::map<int64_t, std::unique_ptr<CaptureSession>> captures_;
  std::map<int64_t, std::unique_ptr<PlaybackSession>> playbacks_;
  int64_t next_session_id_ = 1;
};

}  // namespace audio_flutter_windows

#endif  // FLUTTER_PLUGIN_AUDIO_FLUTTER_WINDOWS_PLUGIN_H_
