export 'src/types.dart';

import 'dart:typed_data';

import 'src/types.dart';
import 'usb_hid_platform_interface.dart';

/// High-level HID facade that mirrors the legacy hid plugin API while adding WebHID support.
class UsbHid {
  UsbHid({UsbHidPlatform? platform})
    : _platform = platform ?? UsbHidPlatform.instance;

  final UsbHidPlatform _platform;

  Stream<HidInputReport> get inputReports => _platform.inputReports;

  /// Whether the native HID backend is available to this app.
  ///
  /// On iPadOS this is `true` only when an app-embedded DriverKit extension
  /// has loaded and exposed a user-client service. Other implementations are
  /// available whenever their platform plugin is registered.
  Future<bool> isDriverAvailable() => _platform.isDriverAvailable();

  Future<List<HidDeviceInfo>> listDevices({List<HidDeviceFilter>? filters}) {
    return _platform.listDevices(filters: filters);
  }

  Future<HidDeviceInfo?> requestDevice({
    required List<HidDeviceFilter> filters,
  }) {
    return _platform.requestDevice(filters: filters);
  }

  Future<HidDevice> openDevice(HidDeviceInfo device) async {
    final handle = await _platform.openDevice(device);
    return HidDevice._(platform: _platform, info: device, handle: handle);
  }
}

/// Handle for operations targeting a specific device.
class HidDevice {
  HidDevice._({
    required UsbHidPlatform platform,
    required this.info,
    required this.handle,
  }) : _platform = platform;

  final UsbHidPlatform _platform;
  final HidDeviceInfo info;
  final HidDeviceHandle handle;

  Future<int> sendOutputReport(Uint8List data, {int reportId = 0}) {
    return _platform.sendOutputReport(handle, reportId, data);
  }

  Future<void> sendFeatureReport(Uint8List data, {int reportId = 0}) {
    return _platform.sendFeatureReport(handle, reportId, data);
  }

  Future<Uint8List?> getFeatureReport({
    int reportId = 0,
    required int reportLength,
  }) {
    return _platform.getFeatureReport(handle, reportId, reportLength);
  }

  Stream<HidInputReport> get inputReports =>
      _platform.inputReports.where((event) => event.deviceId == info.id);

  Future<void> close() => _platform.closeDevice(handle);
}
