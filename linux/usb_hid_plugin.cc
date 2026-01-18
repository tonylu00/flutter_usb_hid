#include "include/usb_hid/usb_hid_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <hidapi/hidapi.h>
#include <gio/gio.h>

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <tuple>
#include <thread>
#include <vector>

#define USB_HID_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), usb_hid_plugin_get_type(), UsbHidPlugin))

namespace {

struct HidDeviceInfo {
  std::string path;
  uint16_t vendor_id{0};
  uint16_t product_id{0};
  uint16_t usage_page{0};
  uint16_t usage{0};
  std::string product_name;
  std::string manufacturer_name;
  std::string serial_number;
  int interface_number{-1};
};

struct OpenHandle {
  int handle_id{0};
  hid_device* device{nullptr};
  HidDeviceInfo info;
  std::atomic<bool> running{false};
  std::thread reader;
};

std::string WideToUtf8(const wchar_t* input) {
  if (!input) return {};
  gsize bytes_written = 0;
  gchar* utf8 = g_utf16_to_utf8(reinterpret_cast<const gunichar2*>(input), -1, nullptr, &bytes_written, nullptr);
  if (!utf8) return {};
  std::string result(utf8, utf8 + bytes_written);
  g_free(utf8);
  return result;
}

HidDeviceInfo DeviceInfoFromNode(const hid_device_info* node) {
  HidDeviceInfo info;
  if (!node) return info;
  info.path = node->path ? node->path : "";
  info.vendor_id = node->vendor_id;
  info.product_id = node->product_id;
  info.usage_page = node->usage_page;
  info.usage = node->usage;
  info.interface_number = node->interface_number;
  if (node->product_string) info.product_name = WideToUtf8(node->product_string);
  if (node->manufacturer_string) info.manufacturer_name = WideToUtf8(node->manufacturer_string);
  if (node->serial_number) info.serial_number = WideToUtf8(node->serial_number);
  return info;
}

FlValue* EncodeDevice(const HidDeviceInfo& info, bool opened) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string(map, "id", fl_value_new_string(info.path.c_str()));
  fl_value_set_string(map, "vendorId", fl_value_new_int(info.vendor_id));
  fl_value_set_string(map, "productId", fl_value_new_int(info.product_id));
  if (!info.product_name.empty()) {
    fl_value_set_string(map, "productName", fl_value_new_string(info.product_name.c_str()));
  }
  if (!info.manufacturer_name.empty()) {
    fl_value_set_string(map, "manufacturerName", fl_value_new_string(info.manufacturer_name.c_str()));
  }
  if (!info.serial_number.empty()) {
    fl_value_set_string(map, "serialNumber", fl_value_new_string(info.serial_number.c_str()));
  }
  if (info.usage_page != 0) {
    fl_value_set_string(map, "usagePage", fl_value_new_int(info.usage_page));
  }
  if (info.usage != 0) {
    fl_value_set_string(map, "usage", fl_value_new_int(info.usage));
  }
  if (info.interface_number >= 0) {
    fl_value_set_string(map, "interfaceNumber", fl_value_new_int(info.interface_number));
  }
  fl_value_set_string(map, "opened", fl_value_new_bool(opened));
  return map;
}

bool MatchesFilters(const HidDeviceInfo& info, FlValue* filters) {
  if (!filters || fl_value_get_type(filters) != FL_VALUE_TYPE_LIST) {
    return true;
  }
  const size_t len = fl_value_get_length(filters);
  for (size_t i = 0; i < len; ++i) {
    FlValue* entry = fl_value_get_list_value(filters, i);
    if (!entry || fl_value_get_type(entry) != FL_VALUE_TYPE_MAP) continue;
    bool match = true;
    FlValue* vendor = fl_value_lookup_string(entry, "vendorId");
    if (vendor && fl_value_get_type(vendor) == FL_VALUE_TYPE_INT) {
      match = match && static_cast<uint16_t>(fl_value_get_int(vendor)) == info.vendor_id;
    }
    FlValue* product = fl_value_lookup_string(entry, "productId");
    if (product && fl_value_get_type(product) == FL_VALUE_TYPE_INT) {
      match = match && static_cast<uint16_t>(fl_value_get_int(product)) == info.product_id;
    }
    FlValue* usage_page = fl_value_lookup_string(entry, "usagePage");
    if (usage_page && fl_value_get_type(usage_page) == FL_VALUE_TYPE_INT) {
      match = match && static_cast<uint16_t>(fl_value_get_int(usage_page)) == info.usage_page;
    }
    FlValue* usage = fl_value_lookup_string(entry, "usage");
    if (usage && fl_value_get_type(usage) == FL_VALUE_TYPE_INT) {
      match = match && static_cast<uint16_t>(fl_value_get_int(usage)) == info.usage;
    }
    if (match) return true;
  }
  return false;
}

std::vector<HidDeviceInfo> EnumerateDevices() {
  std::vector<HidDeviceInfo> devices;
  hid_device_info* head = hid_enumerate(0, 0);
  for (hid_device_info* current = head; current != nullptr; current = current->next) {
    devices.push_back(DeviceInfoFromNode(current));
  }
  hid_free_enumeration(head);
  return devices;
}

}  // namespace

struct _UsbHidPlugin {
  GObject parent_instance;
  FlMethodChannel* method_channel;
  FlEventChannel* event_channel;
  GMainContext* main_context;
  std::mutex mutex;
  std::map<int, std::shared_ptr<OpenHandle>> open_handles;
  int next_handle_id;
};

G_DEFINE_TYPE(UsbHidPlugin, usb_hid_plugin, g_object_get_type())

static void EmitInputReport(UsbHidPlugin* self, const HidDeviceInfo& info, uint8_t report_id, std::vector<uint8_t> data);
static void StopAll(UsbHidPlugin* self);

// Called when a method call is received from Flutter.
static void usb_hid_plugin_handle_method_call(
    UsbHidPlugin* self,
    FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "listDevices") == 0) {
    auto devices = EnumerateDevices();
    g_autoptr(FlValue) result = fl_value_new_list();
    for (const auto& info : devices) {
      fl_value_append_take(result, EncodeDevice(info, false));
    }
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  if (strcmp(method, "requestDevice") == 0) {
    FlValue* filters = nullptr;
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      filters = fl_value_lookup_string(args, "filters");
    }

    auto devices = EnumerateDevices();
    for (const auto& info : devices) {
      if (MatchesFilters(info, filters)) {
        g_autoptr(FlMethodResponse) response =
            FL_METHOD_RESPONSE(fl_method_success_response_new(EncodeDevice(info, false)));
        fl_method_call_respond(method_call, response, nullptr);
        return;
      }
    }

    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  if (strcmp(method, "openDevice") == 0) {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      fl_method_call_respond_error(method_call, "invalid_args", "Expected device map", nullptr, nullptr);
      return;
    }
    FlValue* device_map = fl_value_lookup_string(args, "device");
    if (!device_map || fl_value_get_type(device_map) != FL_VALUE_TYPE_MAP) {
      fl_method_call_respond_error(method_call, "invalid_args", "device must be a map", nullptr, nullptr);
      return;
    }
    FlValue* id_value = fl_value_lookup_string(device_map, "id");
    if (!id_value || fl_value_get_type(id_value) != FL_VALUE_TYPE_STRING) {
      fl_method_call_respond_error(method_call, "invalid_args", "device.id missing", nullptr, nullptr);
      return;
    }
    const gchar* path = fl_value_get_string(id_value);

    HidDeviceInfo info;
    info.path = path ? path : "";
    info.vendor_id = 0;
    info.product_id = 0;
    info.usage_page = 0;
    info.usage = 0;
    info.interface_number = -1;

    auto devices = EnumerateDevices();
    for (const auto& candidate : devices) {
      if (candidate.path == info.path) {
        info = candidate;
        break;
      }
    }

    hid_device* device = hid_open_path(info.path.c_str());
    if (!device) {
      fl_method_call_respond_error(method_call, "open_failed", "Failed to open device", nullptr, nullptr);
      return;
    }

    auto handle = std::make_shared<OpenHandle>();
    handle->device = device;
    handle->info = info;
    wchar_t buffer[256];
    if (hid_get_manufacturer_string(device, buffer, sizeof(buffer) / sizeof(wchar_t)) == 0) {
      handle->info.manufacturer_name = WideToUtf8(buffer);
    }
    if (hid_get_product_string(device, buffer, sizeof(buffer) / sizeof(wchar_t)) == 0) {
      handle->info.product_name = WideToUtf8(buffer);
    }
    if (hid_get_serial_number_string(device, buffer, sizeof(buffer) / sizeof(wchar_t)) == 0) {
      handle->info.serial_number = WideToUtf8(buffer);
    }

    handle->handle_id = self->next_handle_id++;
    {
      std::lock_guard<std::mutex> lock(self->mutex);
      self->open_handles[handle->handle_id] = handle;
    }

    // Start input reader after handle is stored.
    handle->running.store(true);
    handle->reader = std::thread([self, handle]() {
      const size_t kDefaultInputLen = 64;
      while (handle->running.load()) {
        std::vector<uint8_t> buffer(kDefaultInputLen, 0);
        int res = hid_read_timeout(handle->device, buffer.data(), buffer.size(), 500);
        if (res > 0) {
          buffer.resize(static_cast<size_t>(res));
          uint8_t report_id = buffer.empty() ? 0 : buffer[0];
          EmitInputReport(self, handle->info, report_id, std::move(buffer));
        } else if (res == 0) {
          continue;
        } else {
          break;
        }
      }
      handle->running.store(false);
    });

    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string(result, "handle", fl_value_new_int(handle->handle_id));
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  if (strcmp(method, "closeDevice") == 0) {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      fl_method_call_respond_error(method_call, "invalid_args", "Expected handle map", nullptr, nullptr);
      return;
    }
    FlValue* handle_value = fl_value_lookup_string(args, "handle");
    if (!handle_value || fl_value_get_type(handle_value) != FL_VALUE_TYPE_INT) {
      fl_method_call_respond_error(method_call, "invalid_args", "handle missing", nullptr, nullptr);
      return;
    }
    int handle_id = fl_value_get_int(handle_value);
    std::shared_ptr<OpenHandle> owned;
    {
      std::lock_guard<std::mutex> lock(self->mutex);
      auto it = self->open_handles.find(handle_id);
      if (it != self->open_handles.end()) {
        owned = std::move(it->second);
        self->open_handles.erase(it);
      }
    }
    if (owned) {
      owned->running.store(false);
      if (owned->reader.joinable()) {
        owned->reader.join();
      }
      if (owned->device) {
        hid_close(owned->device);
        owned->device = nullptr;
      }
    }
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  if (strcmp(method, "sendOutputReport") == 0) {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      fl_method_call_respond_error(method_call, "invalid_args", "Expected payload", nullptr, nullptr);
      return;
    }
    FlValue* handle_value = fl_value_lookup_string(args, "handle");
    FlValue* report_id_value = fl_value_lookup_string(args, "reportId");
    FlValue* data_value = fl_value_lookup_string(args, "data");
    if (!handle_value || !report_id_value || !data_value) {
      fl_method_call_respond_error(method_call, "invalid_args", "Missing fields", nullptr, nullptr);
      return;
    }
    if (fl_value_get_type(handle_value) != FL_VALUE_TYPE_INT ||
        fl_value_get_type(report_id_value) != FL_VALUE_TYPE_INT ||
        fl_value_get_type(data_value) != FL_VALUE_TYPE_UINT8_LIST) {
      fl_method_call_respond_error(method_call, "invalid_args", "Invalid field types", nullptr, nullptr);
      return;
    }
    int handle_id = fl_value_get_int(handle_value);
    int report_id = fl_value_get_int(report_id_value);
    size_t data_len = 0;
    const uint8_t* data = fl_value_get_uint8_list(data_value, &data_len);

    std::shared_ptr<OpenHandle> handle;
    {
      std::lock_guard<std::mutex> lock(self->mutex);
      auto it = self->open_handles.find(handle_id);
      if (it != self->open_handles.end()) handle = it->second;
    }
    if (!handle || !handle->device) {
      fl_method_call_respond_error(method_call, "not_open", "Handle not found", nullptr, nullptr);
      return;
    }
    std::vector<uint8_t> buffer;
    buffer.reserve(data_len + 1);
    buffer.push_back(static_cast<uint8_t>(report_id));
    buffer.insert(buffer.end(), data, data + data_len);
    int written = hid_write(handle->device, buffer.data(), buffer.size());
    if (written < 0) {
      fl_method_call_respond_error(method_call, "write_failed", "hid_write failed", nullptr, nullptr);
      return;
    }
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_int(written)));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  if (strcmp(method, "sendFeatureReport") == 0) {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      fl_method_call_respond_error(method_call, "invalid_args", "Expected payload", nullptr, nullptr);
      return;
    }
    FlValue* handle_value = fl_value_lookup_string(args, "handle");
    FlValue* report_id_value = fl_value_lookup_string(args, "reportId");
    FlValue* data_value = fl_value_lookup_string(args, "data");
    if (!handle_value || !report_id_value || !data_value) {
      fl_method_call_respond_error(method_call, "invalid_args", "Missing fields", nullptr, nullptr);
      return;
    }
    if (fl_value_get_type(handle_value) != FL_VALUE_TYPE_INT ||
        fl_value_get_type(report_id_value) != FL_VALUE_TYPE_INT ||
        fl_value_get_type(data_value) != FL_VALUE_TYPE_UINT8_LIST) {
      fl_method_call_respond_error(method_call, "invalid_args", "Invalid field types", nullptr, nullptr);
      return;
    }
    int handle_id = fl_value_get_int(handle_value);
    int report_id = fl_value_get_int(report_id_value);
    size_t data_len = 0;
    const uint8_t* data = fl_value_get_uint8_list(data_value, &data_len);

    std::shared_ptr<OpenHandle> handle;
    {
      std::lock_guard<std::mutex> lock(self->mutex);
      auto it = self->open_handles.find(handle_id);
      if (it != self->open_handles.end()) handle = it->second;
    }
    if (!handle || !handle->device) {
      fl_method_call_respond_error(method_call, "not_open", "Handle not found", nullptr, nullptr);
      return;
    }
    std::vector<uint8_t> buffer;
    buffer.reserve(data_len + 1);
    buffer.push_back(static_cast<uint8_t>(report_id));
    buffer.insert(buffer.end(), data, data + data_len);
    int res = hid_send_feature_report(handle->device, buffer.data(), buffer.size());
    if (res < 0) {
      fl_method_call_respond_error(method_call, "feature_failed", "hid_send_feature_report failed", nullptr, nullptr);
      return;
    }
    g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  if (strcmp(method, "getFeatureReport") == 0) {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      fl_method_call_respond_error(method_call, "invalid_args", "Expected payload", nullptr, nullptr);
      return;
    }
    FlValue* handle_value = fl_value_lookup_string(args, "handle");
    FlValue* report_id_value = fl_value_lookup_string(args, "reportId");
    FlValue* length_value = fl_value_lookup_string(args, "length");
    if (!handle_value || !report_id_value || !length_value) {
      fl_method_call_respond_error(method_call, "invalid_args", "Missing fields", nullptr, nullptr);
      return;
    }
    if (fl_value_get_type(handle_value) != FL_VALUE_TYPE_INT ||
        fl_value_get_type(report_id_value) != FL_VALUE_TYPE_INT ||
        fl_value_get_type(length_value) != FL_VALUE_TYPE_INT) {
      fl_method_call_respond_error(method_call, "invalid_args", "Invalid field types", nullptr, nullptr);
      return;
    }
    int handle_id = fl_value_get_int(handle_value);
    int report_id = fl_value_get_int(report_id_value);
    int length = fl_value_get_int(length_value);

    std::shared_ptr<OpenHandle> handle;
    {
      std::lock_guard<std::mutex> lock(self->mutex);
      auto it = self->open_handles.find(handle_id);
      if (it != self->open_handles.end()) handle = it->second;
    }
    if (!handle || !handle->device) {
      fl_method_call_respond_error(method_call, "not_open", "Handle not found", nullptr, nullptr);
      return;
    }

    std::vector<uint8_t> buffer(static_cast<size_t>(length) + 1, 0);
    buffer[0] = static_cast<uint8_t>(report_id);
    int res = hid_get_feature_report(handle->device, buffer.data(), buffer.size());
    if (res < 0) {
      g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      fl_method_call_respond(method_call, response, nullptr);
      return;
    }
    buffer.resize(static_cast<size_t>(res));
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_uint8_list(buffer.data(), buffer.size())));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }

  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(method_call, response, nullptr);
}

static gboolean EmitEventOnMain(gpointer user_data) {
  std::unique_ptr<std::tuple<UsbHidPlugin*, HidDeviceInfo, uint8_t, std::vector<uint8_t>>> payload(
      static_cast<std::tuple<UsbHidPlugin*, HidDeviceInfo, uint8_t, std::vector<uint8_t>>*>(user_data));
  UsbHidPlugin* plugin = std::get<0>(*payload);
  const HidDeviceInfo& info = std::get<1>(*payload);
  uint8_t report_id = std::get<2>(*payload);
  const std::vector<uint8_t>& data = std::get<3>(*payload);

  FlValue* map = fl_value_new_map();
  fl_value_set_string(map, "deviceId", fl_value_new_string(info.path.c_str()));
  fl_value_set_string(map, "reportId", fl_value_new_int(report_id));
  fl_value_set_string(map, "data", fl_value_new_uint8_list(data.data(), data.size()));
  fl_event_channel_send(plugin->event_channel, map, nullptr, nullptr);
  g_object_unref(plugin);
  return G_SOURCE_REMOVE;
}

static void EmitInputReport(UsbHidPlugin* self, const HidDeviceInfo& info, uint8_t report_id, std::vector<uint8_t> data) {
  if (!self->main_context) return;
  auto* payload = new std::tuple<UsbHidPlugin*, HidDeviceInfo, uint8_t, std::vector<uint8_t>>(USB_HID_PLUGIN(g_object_ref(self)), info, report_id, std::move(data));
  g_main_context_invoke(self->main_context, EmitEventOnMain, payload);
}

static void StopAll(UsbHidPlugin* self) {
  std::map<int, std::shared_ptr<OpenHandle>> handles;
  {
    std::lock_guard<std::mutex> lock(self->mutex);
    handles.swap(self->open_handles);
  }
  for (auto& entry : handles) {
    auto handle = entry.second;
    if (!handle) continue;
    handle->running.store(false);
    if (handle->reader.joinable()) {
      handle->reader.join();
    }
    if (handle->device) {
      hid_close(handle->device);
      handle->device = nullptr;
    }
  }
}

static void usb_hid_plugin_dispose(GObject* object) {
  auto* self = USB_HID_PLUGIN(object);
  StopAll(self);
  if (self->event_channel) {
    fl_event_channel_send_end_of_stream(self->event_channel, nullptr, nullptr);
  }
  if (self->main_context) {
    g_main_context_unref(self->main_context);
    self->main_context = nullptr;
  }
  hid_exit();

  G_OBJECT_CLASS(usb_hid_plugin_parent_class)->dispose(object);
}

static void usb_hid_plugin_class_init(UsbHidPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = usb_hid_plugin_dispose;
}

static void usb_hid_plugin_init(UsbHidPlugin* self) {
  self->method_channel = nullptr;
  self->event_channel = nullptr;
  self->main_context = g_main_context_ref_thread_default();
  if (!self->main_context) {
    self->main_context = g_main_context_ref(g_main_context_default());
  }
  self->next_handle_id = 1;
  hid_init();
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  UsbHidPlugin* plugin = USB_HID_PLUGIN(user_data);
  usb_hid_plugin_handle_method_call(plugin, method_call);
}

static FlMethodErrorResponse* on_listen_cb(FlEventChannel* channel, FlValue* args, gpointer user_data) {
  return nullptr;
}

static FlMethodErrorResponse* on_cancel_cb(FlEventChannel* channel, FlValue* args, gpointer user_data) {
  return nullptr;
}

void usb_hid_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  UsbHidPlugin* plugin = USB_HID_PLUGIN(
      g_object_new(usb_hid_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->method_channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "usb_hid/methods",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->method_channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  plugin->event_channel = fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
                             "usb_hid/input_reports",
                             FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(plugin->event_channel, on_listen_cb, on_cancel_cb,
                                       g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
