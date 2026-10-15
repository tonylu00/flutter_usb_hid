#ifndef FLUTTER_PLUGIN_USB_HID_PLUGIN_H_
#define FLUTTER_PLUGIN_USB_HID_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <deque>
#include <optional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace usb_hid {

class InputReportStreamHandler;

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
  uint16_t input_report_len = 0;
  // HidP_GetCaps OutputReportByteLength (report id included): Windows
  // refuses an output report WriteFile of any other length.
  uint16_t output_report_len = 0;
  // Troubleshooting counters (getDiagnostics).
  std::atomic<uint32_t> reads_ok{0};
  std::atomic<uint32_t> read_timeouts{0};
  std::atomic<uint32_t> read_errors{0};
  std::atomic<uint32_t> last_read_error{0};
  std::atomic<bool> reader_stopped{false};
  std::atomic<bool> running{false};
  std::thread reader;
};

// An input report read on a reader thread, waiting for the platform thread.
struct PendingInputReport {
  std::string device_id;
  uint8_t report_id;
  std::vector<uint8_t> data;
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
  void DrainInputReports();
  static LRESULT CALLBACK MessageWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

    friend class InputReportStreamHandler;

  std::mutex mutex_;
  int next_handle_id_ = 1;
  std::unordered_map<int, std::unique_ptr<OpenHandle>> open_handles_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> input_report_sink_;
  // Event sinks must be used on the platform thread: reader threads queue
  // their reports and post kInputReportMessage to this plugin's own
  // message-only window, created on the platform thread (the runner's view
  // is not yet parented when plugins register, so the top-level window
  // cannot be found then).
  HWND window_ = nullptr;
  std::atomic<uint32_t> reports_posted_{0};
  std::atomic<uint32_t> reports_delivered_{0};
  std::atomic<uint32_t> reports_dropped_{0};
  std::atomic<uint32_t> post_failures_{0};
  std::deque<PendingInputReport> pending_reports_;
};

}  // namespace usb_hid

#endif  // FLUTTER_PLUGIN_USB_HID_PLUGIN_H_
