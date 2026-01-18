#ifndef FLUTTER_PLUGIN_USB_HID_PLUGIN_H_
#define FLUTTER_PLUGIN_USB_HID_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace usb_hid {

struct HidDeviceInfo {
  std::string path;
  uint16_t vendor_id;
  uint16_t product_id;
  uint16_t usage_page;
  uint16_t usage;
  std::string product_name;
  std::string manufacturer_name;
  std::string serial_number;
};

struct OpenHandle {
  int handle_id;
  HidDeviceInfo info;
  HANDLE file_handle;
  uint16_t input_report_len;
  std::atomic<bool> running{false};
  std::thread reader;
};

class UsbHidPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  UsbHidPlugin();

  virtual ~UsbHidPlugin();

  // Disallow copy and assign.
  UsbHidPlugin(const UsbHidPlugin&) = delete;
  UsbHidPlugin& operator=(const UsbHidPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  std::vector<HidDeviceInfo> EnumerateDevices();
  static bool MatchesFilters(const HidDeviceInfo &info, const flutter::EncodableList *filters);
  static flutter::EncodableMap EncodeDevice(const HidDeviceInfo &info, bool opened = false);
  std::unique_ptr<OpenHandle> OpenDevice(const std::string &path);
  void StartReader(OpenHandle &handle);
  void StopAll();
  void EmitInputReport(const HidDeviceInfo &info, uint8_t report_id, const std::vector<uint8_t> &data);

  std::mutex mutex_;
  int next_handle_id_ = 1;
  std::unordered_map<int, std::unique_ptr<OpenHandle>> open_handles_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> input_report_sink_;
};

}  // namespace usb_hid

#endif  // FLUTTER_PLUGIN_USB_HID_PLUGIN_H_
