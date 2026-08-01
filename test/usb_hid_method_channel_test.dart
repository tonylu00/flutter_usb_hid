import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:usb_hid/usb_hid_method_channel.dart';
import 'package:usb_hid/usb_hid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelUsbHid platform = MethodChannelUsbHid();
  const MethodChannel channel = MethodChannel('usb_hid/methods');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          if (methodCall.method == 'listDevices') {
            return <Map<String, Object?>>[];
          }
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('listDevices returns empty list', () async {
    final hid = UsbHid(platform: platform);
    expect(await hid.listDevices(), isEmpty);
  });

  test('isDriverAvailable probes the iPadOS DriverKit service', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
          if (methodCall.method == 'isDriverAvailable') {
            return true;
          }
          return null;
        });

    final hid = UsbHid(platform: platform);
    expect(await hid.isDriverAvailable(), isTrue);
  });
}
