#include "include/usb_hid/usb_hid_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "usb_hid_plugin.h"

void UsbHidPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  usb_hid::UsbHidPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
