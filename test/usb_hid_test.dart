import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:usb_hid/usb_hid.dart';
import 'package:usb_hid/usb_hid_method_channel.dart';
import 'package:usb_hid/usb_hid_platform_interface.dart';

class MockUsbHidPlatform with MockPlatformInterfaceMixin implements UsbHidPlatform {
  @override
  Stream<HidInputReport> get inputReports => const Stream.empty();

  @override
  Future<void> closeDevice(HidDeviceHandle handle) async {}

  @override
  Future<Uint8List?> getFeatureReport(HidDeviceHandle handle, int reportId, int reportLength) async => null;

  @override
  Future<List<HidDeviceInfo>> listDevices({List<HidDeviceFilter>? filters}) async => const [];

  @override
  Future<HidDeviceHandle> openDevice(HidDeviceInfo device) async => HidDeviceHandle(deviceId: device.id, handle: 1);

  @override
  Future<HidDeviceInfo?> requestDevice({required List<HidDeviceFilter> filters}) async => null;

  @override
  Future<void> sendFeatureReport(HidDeviceHandle handle, int reportId, Uint8List data) async {}

  @override
  Future<int> sendOutputReport(HidDeviceHandle handle, int reportId, Uint8List data) async => data.length;
}

void main() {
  final UsbHidPlatform initialPlatform = UsbHidPlatform.instance;

  test('$MethodChannelUsbHid is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelUsbHid>());
  });

  test('listDevices returns empty list by default', () async {
    final usbHid = UsbHid(platform: MockUsbHidPlatform());
    final devices = await usbHid.listDevices();
    expect(devices, isEmpty);
  });
}
