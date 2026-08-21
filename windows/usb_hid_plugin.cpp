#include "usb_hid_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <hidsdi.h>
#include <setupapi.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <codecvt>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace usb_hid {

class InputReportStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit InputReportStreamHandler(UsbHidPlugin *plugin) : plugin_(plugin) {}

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue *arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> &&events) override {
    plugin_->input_report_sink_ = std::move(events);
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(
      const flutter::EncodableValue *arguments) override {
    plugin_->input_report_sink_ = nullptr;
    return nullptr;
  }

 private:
  UsbHidPlugin *plugin_;
};

// static
void UsbHidPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "usb_hid/methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "usb_hid/input_reports",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<UsbHidPlugin>();
  auto plugin_pointer = plugin.get();

  channel->SetMethodCallHandler(
      [plugin_pointer](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto stream_handler = std::make_unique<InputReportStreamHandler>(plugin_pointer);

  event_channel->SetStreamHandler(std::move(stream_handler));

  registrar->AddPlugin(std::move(plugin));
}

UsbHidPlugin::UsbHidPlugin() {}

UsbHidPlugin::~UsbHidPlugin() { StopAll(); }

namespace {

using HidStringGetter = BOOLEAN(__stdcall *)(HANDLE, PVOID, ULONG);

std::string WideToUtf8(const std::wstring &input) {
  if (input.empty()) return {};
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, input.c_str(), (int)input.size(), nullptr, 0, nullptr, nullptr);
  std::string str_to(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, input.c_str(), (int)input.size(), &str_to[0], size_needed, nullptr, nullptr);
  return str_to;
}

std::string HidString(HANDLE handle, HidStringGetter getter, ULONG max_len_chars = 256) {
  std::wstring buffer;
  buffer.resize(max_len_chars);
  if (getter(handle, buffer.data(), max_len_chars * sizeof(wchar_t))) {
    buffer.resize(wcsnlen_s(buffer.c_str(), max_len_chars));
    return WideToUtf8(buffer);
  }
  return {};
}

}  // namespace

void UsbHidPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto &method_name = method_call.method_name();
  const auto *args = std::get_if<flutter::EncodableMap>(method_call.arguments());

  try {
    if (method_name == "listDevices") {
      auto devices = EnumerateDevices();
      flutter::EncodableList encoded;
      encoded.reserve(devices.size());
      for (const auto &dev : devices) {
        encoded.push_back(EncodeDevice(dev));
      }
      result->Success(encoded);
      return;
    }

    if (method_name == "requestDevice") {
      const auto *filters = args ? std::get_if<flutter::EncodableList>(&args->at(flutter::EncodableValue("filters"))) : nullptr;
      auto devices = EnumerateDevices();
      for (const auto &dev : devices) {
        if (!filters || MatchesFilters(dev, filters)) {
          result->Success(EncodeDevice(dev));
          return;
        }
      }
      result->Success(nullptr);
      return;
    }

    if (method_name == "openDevice") {
      if (!args) {
        result->Error("invalid_args", "Expected device map", nullptr);
        return;
      }
      const auto &device_entry = args->at(flutter::EncodableValue("device"));
      const auto *device_map = std::get_if<flutter::EncodableMap>(&device_entry);
      if (!device_map) {
        result->Error("invalid_args", "device must be map", nullptr);
        return;
      }
      auto it = device_map->find(flutter::EncodableValue("id"));
      if (it == device_map->end()) {
        result->Error("invalid_args", "device.id missing", nullptr);
        return;
      }
      auto path = std::get<std::string>(it->second);
      auto handle = OpenDevice(path);
      if (!handle) {
        result->Error("open_failed", "Failed to open device", nullptr);
        return;
      }
      int handle_id = handle->handle_id;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        open_handles_[handle_id] = std::move(handle);
      }
      result->Success(flutter::EncodableMap{{flutter::EncodableValue("handle"), flutter::EncodableValue(handle_id)}});
      return;
    }

    if (method_name == "closeDevice") {
      if (!args) {
        result->Error("invalid_args", "Expected handle", nullptr);
        return;
      }
      int handle = std::get<int32_t>(args->at(flutter::EncodableValue("handle")));
      std::unique_ptr<OpenHandle> owned;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = open_handles_.find(handle);
        if (it != open_handles_.end()) {
          owned = std::move(it->second);
          open_handles_.erase(it);
        }
      }
      if (owned) {
        owned->running.store(false);
        CancelIoEx(owned->file_handle, nullptr);
        if (owned->reader.joinable()) {
          owned->reader.join();
        }
        CloseHandle(owned->file_handle);
      }
      result->Success();
      return;
    }

    if (method_name == "sendOutputReport") {
      if (!args) {
        result->Error("invalid_args", "Expected payload", nullptr);
        return;
      }
      int handle = std::get<int32_t>(args->at(flutter::EncodableValue("handle")));
      int report_id = std::get<int32_t>(args->at(flutter::EncodableValue("reportId")));
      const auto &data_any = args->at(flutter::EncodableValue("data"));
      const auto *bytes = std::get_if<std::vector<uint8_t>>(&data_any);
      if (!bytes) {
        result->Error("invalid_args", "data must be uint8 list", nullptr);
        return;
      }
      std::unique_ptr<OpenHandle> *handle_ptr = nullptr;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = open_handles_.find(handle);
        if (it != open_handles_.end()) {
          handle_ptr = &it->second;
        }
      }
      if (!handle_ptr || !*handle_ptr) {
        result->Error("not_open", "Handle not found", nullptr);
        return;
      }
      std::vector<uint8_t> buffer;
      buffer.reserve(bytes->size() + 1);
      buffer.push_back(static_cast<uint8_t>(report_id));
      buffer.insert(buffer.end(), bytes->begin(), bytes->end());
      DWORD written = 0;
      if (!WriteFile((*handle_ptr)->file_handle, buffer.data(), static_cast<DWORD>(buffer.size()), &written, nullptr)) {
        result->Error("write_failed", "WriteFile failed", nullptr);
        return;
      }
      result->Success(flutter::EncodableValue(static_cast<int>(written)));
      return;
    }

    if (method_name == "sendFeatureReport") {
      if (!args) {
        result->Error("invalid_args", "Expected payload", nullptr);
        return;
      }
      int handle = std::get<int32_t>(args->at(flutter::EncodableValue("handle")));
      int report_id = std::get<int32_t>(args->at(flutter::EncodableValue("reportId")));
      const auto &data_any = args->at(flutter::EncodableValue("data"));
      const auto *bytes = std::get_if<std::vector<uint8_t>>(&data_any);
      if (!bytes) {
        result->Error("invalid_args", "data must be uint8 list", nullptr);
        return;
      }
      std::unique_ptr<OpenHandle> *handle_ptr = nullptr;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = open_handles_.find(handle);
        if (it != open_handles_.end()) {
          handle_ptr = &it->second;
        }
      }
      if (!handle_ptr || !*handle_ptr) {
        result->Error("not_open", "Handle not found", nullptr);
        return;
      }
      std::vector<uint8_t> buffer;
      buffer.reserve(bytes->size() + 1);
      buffer.push_back(static_cast<uint8_t>(report_id));
      buffer.insert(buffer.end(), bytes->begin(), bytes->end());
      if (!HidD_SetFeature((*handle_ptr)->file_handle, buffer.data(), static_cast<ULONG>(buffer.size()))) {
        result->Error("feature_failed", "HidD_SetFeature failed", nullptr);
        return;
      }
      result->Success();
      return;
    }

    if (method_name == "getFeatureReport") {
      if (!args) {
        result->Error("invalid_args", "Expected payload", nullptr);
        return;
      }
      int handle = std::get<int32_t>(args->at(flutter::EncodableValue("handle")));
      int report_id = std::get<int32_t>(args->at(flutter::EncodableValue("reportId")));
      int length = std::get<int32_t>(args->at(flutter::EncodableValue("length")));

      std::unique_ptr<OpenHandle> *handle_ptr = nullptr;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = open_handles_.find(handle);
        if (it != open_handles_.end()) {
          handle_ptr = &it->second;
        }
      }
      if (!handle_ptr || !*handle_ptr) {
        result->Error("not_open", "Handle not found", nullptr);
        return;
      }

      std::vector<uint8_t> buffer(static_cast<size_t>(length) + 1, 0);
      buffer[0] = static_cast<uint8_t>(report_id);
      if (!HidD_GetFeature((*handle_ptr)->file_handle, buffer.data(), static_cast<ULONG>(buffer.size()))) {
        result->Success(flutter::EncodableValue());
        return;
      }
      buffer.resize(static_cast<size_t>(length) + 1);
      result->Success(flutter::EncodableValue(buffer));
      return;
    }

  } catch (const std::exception &ex) {
    result->Error("exception", ex.what(), nullptr);
    return;
  }

  result->NotImplemented();
}

std::vector<HidDeviceInfo> UsbHidPlugin::EnumerateDevices() {
  std::vector<HidDeviceInfo> devices;

  GUID hid_guid;
  HidD_GetHidGuid(&hid_guid);
  HDEVINFO device_info = SetupDiGetClassDevs(&hid_guid, nullptr, nullptr, DIGCF_DEVICEINTERFACE | DIGCF_PRESENT);
  if (device_info == INVALID_HANDLE_VALUE) {
    return devices;
  }

  SP_DEVICE_INTERFACE_DATA device_interface_data;
  device_interface_data.cbSize = sizeof(SP_DEVICE_INTERFACE_DATA);
  for (DWORD index = 0; SetupDiEnumDeviceInterfaces(device_info, nullptr, &hid_guid, index, &device_interface_data); ++index) {
    DWORD required_size = 0;
    SetupDiGetDeviceInterfaceDetail(device_info, &device_interface_data, nullptr, 0, &required_size, nullptr);
    std::vector<uint8_t> detail_buffer(required_size);
    auto detail_data = reinterpret_cast<PSP_DEVICE_INTERFACE_DETAIL_DATA>(detail_buffer.data());
    detail_data->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA);
    if (!SetupDiGetDeviceInterfaceDetail(device_info, &device_interface_data, detail_data, required_size, nullptr, nullptr)) {
      continue;
    }

        std::string path =
    #ifdef UNICODE
      WideToUtf8(detail_data->DevicePath);
    #else
      std::string(detail_data->DevicePath);
    #endif
    HANDLE device_handle = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE,
                                       FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                                       FILE_FLAG_OVERLAPPED, nullptr);
    if (device_handle == INVALID_HANDLE_VALUE) {
      continue;
    }

    HIDD_ATTRIBUTES attributes;
    attributes.Size = sizeof(HIDD_ATTRIBUTES);
    if (!HidD_GetAttributes(device_handle, &attributes)) {
      CloseHandle(device_handle);
      continue;
    }

    PHIDP_PREPARSED_DATA preparsed = nullptr;
    HIDP_CAPS caps;
    uint16_t usage_page = 0;
    uint16_t usage = 0;
    if (HidD_GetPreparsedData(device_handle, &preparsed)) {
      if (HidP_GetCaps(preparsed, &caps) == HIDP_STATUS_SUCCESS) {
        usage_page = caps.UsagePage;
        usage = caps.Usage;
      }
      HidD_FreePreparsedData(preparsed);
    }

    HidDeviceInfo info{
        path,
        static_cast<uint16_t>(attributes.VendorID),
        static_cast<uint16_t>(attributes.ProductID),
        usage_page,
        usage,
        HidString(device_handle, &HidD_GetProductString),
        HidString(device_handle, &HidD_GetManufacturerString),
        HidString(device_handle, &HidD_GetSerialNumberString),
    };

    devices.push_back(std::move(info));
    CloseHandle(device_handle);
  }

  SetupDiDestroyDeviceInfoList(device_info);
  return devices;
}

bool UsbHidPlugin::MatchesFilters(const HidDeviceInfo &info, const flutter::EncodableList *filters) {
  if (!filters) return true;
  for (const auto &entry : *filters) {
    const auto *filter_map = std::get_if<flutter::EncodableMap>(&entry);
    if (!filter_map) continue;
    bool match = true;
    auto it_vid = filter_map->find(flutter::EncodableValue("vendorId"));
    if (it_vid != filter_map->end() && std::holds_alternative<int32_t>(it_vid->second)) {
      match = match && static_cast<uint16_t>(std::get<int32_t>(it_vid->second)) == info.vendor_id;
    }
    auto it_pid = filter_map->find(flutter::EncodableValue("productId"));
    if (it_pid != filter_map->end() && std::holds_alternative<int32_t>(it_pid->second)) {
      match = match && static_cast<uint16_t>(std::get<int32_t>(it_pid->second)) == info.product_id;
    }
    auto it_usage_page = filter_map->find(flutter::EncodableValue("usagePage"));
    if (it_usage_page != filter_map->end() && std::holds_alternative<int32_t>(it_usage_page->second)) {
      match = match && static_cast<uint16_t>(std::get<int32_t>(it_usage_page->second)) == info.usage_page;
    }
    auto it_usage = filter_map->find(flutter::EncodableValue("usage"));
    if (it_usage != filter_map->end() && std::holds_alternative<int32_t>(it_usage->second)) {
      match = match && static_cast<uint16_t>(std::get<int32_t>(it_usage->second)) == info.usage;
    }
    if (match) return true;
  }
  return false;
}

flutter::EncodableMap UsbHidPlugin::EncodeDevice(const HidDeviceInfo &info, bool opened) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("id")] = flutter::EncodableValue(info.path);
  map[flutter::EncodableValue("vendorId")] = flutter::EncodableValue(static_cast<int>(info.vendor_id));
  map[flutter::EncodableValue("productId")] = flutter::EncodableValue(static_cast<int>(info.product_id));
  if (!info.product_name.empty()) map[flutter::EncodableValue("productName")] = flutter::EncodableValue(info.product_name);
  if (!info.manufacturer_name.empty()) map[flutter::EncodableValue("manufacturerName")] = flutter::EncodableValue(info.manufacturer_name);
  if (!info.serial_number.empty()) map[flutter::EncodableValue("serialNumber")] = flutter::EncodableValue(info.serial_number);
  if (info.usage_page != 0) map[flutter::EncodableValue("usagePage")] = flutter::EncodableValue(static_cast<int>(info.usage_page));
  if (info.usage != 0) map[flutter::EncodableValue("usage")] = flutter::EncodableValue(static_cast<int>(info.usage));
  map[flutter::EncodableValue("opened")] = flutter::EncodableValue(opened);
  return map;
}

std::unique_ptr<OpenHandle> UsbHidPlugin::OpenDevice(const std::string &path) {
  auto handle = std::make_unique<OpenHandle>();
  handle->handle_id = next_handle_id_++;
  handle->info.path = path;

  HANDLE file = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                           FILE_FLAG_OVERLAPPED, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return nullptr;
  }

  handle->file_handle = file;

  HIDD_ATTRIBUTES attributes;
  attributes.Size = sizeof(HIDD_ATTRIBUTES);
  if (HidD_GetAttributes(file, &attributes)) {
    handle->info.vendor_id = static_cast<uint16_t>(attributes.VendorID);
    handle->info.product_id = static_cast<uint16_t>(attributes.ProductID);
  }

  PHIDP_PREPARSED_DATA preparsed = nullptr;
  HIDP_CAPS caps;
  if (HidD_GetPreparsedData(file, &preparsed)) {
    if (HidP_GetCaps(preparsed, &caps) == HIDP_STATUS_SUCCESS) {
      handle->info.usage_page = caps.UsagePage;
      handle->info.usage = caps.Usage;
      handle->input_report_len = caps.InputReportByteLength;
    }
    HidD_FreePreparsedData(preparsed);
  }

  handle->info.product_name = HidString(file, &HidD_GetProductString);
  handle->info.manufacturer_name = HidString(file, &HidD_GetManufacturerString);
  handle->info.serial_number = HidString(file, &HidD_GetSerialNumberString);

  StartReader(*handle);
  return handle;
}

void UsbHidPlugin::StartReader(OpenHandle &handle) {
  handle.running.store(true);
  handle.reader = std::thread([this, &handle]() {
    const size_t report_len = handle.input_report_len ? handle.input_report_len : 64;
    while (handle.running.load()) {
      std::vector<uint8_t> buffer(report_len, 0);
      OVERLAPPED ov = {};
      ov.hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
      if (!ov.hEvent) {
        break;
      }
      if (!ReadFile(handle.file_handle, buffer.data(), static_cast<DWORD>(buffer.size()), nullptr, &ov)) {
        auto err = GetLastError();
        if (err != ERROR_IO_PENDING) {
          CloseHandle(ov.hEvent);
          break;
        }
      }
      DWORD wait = WaitForSingleObject(ov.hEvent, 500);
      if (wait == WAIT_OBJECT_0) {
        DWORD read = 0;
        if (GetOverlappedResult(handle.file_handle, &ov, &read, FALSE) && read > 0) {
          uint8_t report_id = buffer.empty() ? 0 : buffer[0];
          buffer.resize(read);
          // Win32 HID reads include the report ID at byte zero. The Dart API
          // exposes it separately, matching IOHID and WebHID semantics.
          buffer.erase(buffer.begin());
          EmitInputReport(handle.info, report_id, buffer);
        }
      } else {
        CancelIoEx(handle.file_handle, &ov);
      }
      CloseHandle(ov.hEvent);
    }
  });
}

void UsbHidPlugin::EmitInputReport(const HidDeviceInfo &info, uint8_t report_id, const std::vector<uint8_t> &data) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!input_report_sink_) return;
  flutter::EncodableMap map;
  map[flutter::EncodableValue("deviceId")] = flutter::EncodableValue(info.path);
  map[flutter::EncodableValue("reportId")] = flutter::EncodableValue(static_cast<int>(report_id));
  map[flutter::EncodableValue("data")] = flutter::EncodableValue(data);
  input_report_sink_->Success(map);
}

void UsbHidPlugin::StopAll() {
  std::unordered_map<int, std::unique_ptr<OpenHandle>> handles;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    handles.swap(open_handles_);
  }
  for (auto &entry : handles) {
    auto &handle = entry.second;
    handle->running.store(false);
    CancelIoEx(handle->file_handle, nullptr);
    if (handle->reader.joinable()) {
      handle->reader.join();
    }
    CloseHandle(handle->file_handle);
  }
}

}  // namespace usb_hid
