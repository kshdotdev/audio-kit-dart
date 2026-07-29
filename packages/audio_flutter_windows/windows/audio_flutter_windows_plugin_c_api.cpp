#include "include/audio_flutter_windows/audio_flutter_windows_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "audio_flutter_windows_plugin.h"

void AudioFlutterWindowsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  audio_flutter_windows::AudioFlutterWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
