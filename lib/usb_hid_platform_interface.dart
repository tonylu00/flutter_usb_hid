import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'src/types.dart';
import 'usb_hid_method_channel.dart';

abstract class UsbHidPlatform extends PlatformInterface {
  UsbHidPlatform() : super(token: _token);

  static final Object _token = Object();

  static UsbHidPlatform _instance = MethodChannelUsbHid();

  static UsbHidPlatform get instance => _instance;

  static set instance(UsbHidPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Whether the native backend can currently service HID requests.
  ///
  /// Platforms that do not require a separately provisioned driver are
  /// available by default. The iOS method-channel implementation overrides
  /// this with a DriverKit service probe.
  Future<bool> isDriverAvailable() async => true;

  /// Enumerate already-permitted HID devices.
  Future<List<HidDeviceInfo>> listDevices({List<HidDeviceFilter>? filters});

  /// Request access to a device (may show a prompt on Web).
  Future<HidDeviceInfo?> requestDevice({
    required List<HidDeviceFilter> filters,
  });

  /// Open a device by id and return an opaque handle.
  Future<HidDeviceHandle> openDevice(HidDeviceInfo device);

  /// Close a previously opened handle.
  Future<void> closeDevice(HidDeviceHandle handle);

  /// Write an output report to the device.
  Future<int> sendOutputReport(
    HidDeviceHandle handle,
    int reportId,
    Uint8List data,
  );

  /// Send a feature report (usually control transfer).
  Future<void> sendFeatureReport(
    HidDeviceHandle handle,
    int reportId,
    Uint8List data,
  );

  /// Read a feature report from the device.
  Future<Uint8List?> getFeatureReport(
    HidDeviceHandle handle,
    int reportId,
    int reportLength,
  );

  /// Stream of input reports across all open devices.
  Stream<HidInputReport> get inputReports;
}
