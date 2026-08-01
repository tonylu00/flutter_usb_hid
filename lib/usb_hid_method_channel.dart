import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/types.dart';
import 'usb_hid_platform_interface.dart';

/// An implementation of [UsbHidPlatform] that uses method and event channels.
class MethodChannelUsbHid extends UsbHidPlatform {
  @visibleForTesting
  static const MethodChannel methodChannel = MethodChannel('usb_hid/methods');

  @visibleForTesting
  static const EventChannel inputReportsChannel = EventChannel(
    'usb_hid/input_reports',
  );

  Stream<HidInputReport>? _inputReports;

  @override
  Future<bool> isDriverAvailable() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return true;
    }
    return await methodChannel.invokeMethod<bool>('isDriverAvailable') ?? false;
  }

  @override
  Future<List<HidDeviceInfo>> listDevices({
    List<HidDeviceFilter>? filters,
  }) async {
    final response = await methodChannel.invokeListMethod<Object?>(
      'listDevices',
      {'filters': filters?.map((filter) => filter.toMap()).toList()},
    );

    return (response ?? const <Object?>[])
        .map((entry) => HidDeviceInfo.fromMap(entry as Map<dynamic, dynamic>))
        .toList();
  }

  @override
  Future<HidDeviceInfo?> requestDevice({
    required List<HidDeviceFilter> filters,
  }) async {
    final response = await methodChannel.invokeMapMethod<String, Object?>(
      'requestDevice',
      {'filters': filters.map((filter) => filter.toMap()).toList()},
    );

    if (response == null) {
      return null;
    }
    return HidDeviceInfo.fromMap(response);
  }

  @override
  Future<HidDeviceHandle> openDevice(HidDeviceInfo device) async {
    final response = await methodChannel.invokeMapMethod<String, Object?>(
      'openDevice',
      {'device': device.toMap()},
    );
    final handle =
        (response?['handle'] as int?) ??
        (throw PlatformException(
          code: 'no_handle',
          message: 'Platform failed to return a handle',
        ));
    return HidDeviceHandle(deviceId: device.id, handle: handle);
  }

  @override
  Future<void> closeDevice(HidDeviceHandle handle) {
    return methodChannel.invokeMethod<void>('closeDevice', {
      'handle': handle.handle,
    });
  }

  @override
  Future<int> sendOutputReport(
    HidDeviceHandle handle,
    int reportId,
    Uint8List data,
  ) async {
    final bytesWritten = await methodChannel.invokeMethod<int>(
      'sendOutputReport',
      {'handle': handle.handle, 'reportId': reportId, 'data': data},
    );
    return bytesWritten ?? 0;
  }

  @override
  Future<void> sendFeatureReport(
    HidDeviceHandle handle,
    int reportId,
    Uint8List data,
  ) {
    return methodChannel.invokeMethod<void>('sendFeatureReport', {
      'handle': handle.handle,
      'reportId': reportId,
      'data': data,
    });
  }

  @override
  Future<Uint8List?> getFeatureReport(
    HidDeviceHandle handle,
    int reportId,
    int reportLength,
  ) async {
    final response = await methodChannel.invokeMethod<Object?>(
      'getFeatureReport',
      {'handle': handle.handle, 'reportId': reportId, 'length': reportLength},
    );

    if (response == null) {
      return null;
    }

    if (response is Uint8List) {
      return response;
    }

    if (response is List<int>) {
      return Uint8List.fromList(response);
    }

    throw PlatformException(
      code: 'invalid_response',
      message: 'Unexpected feature report payload type ${response.runtimeType}',
    );
  }

  @override
  Stream<HidInputReport> get inputReports {
    _inputReports ??= inputReportsChannel.receiveBroadcastStream().map((event) {
      final map = event as Map<dynamic, dynamic>;
      final deviceId = map['deviceId'] as String;
      final reportId = map['reportId'] as int? ?? 0;
      final data = map['data'];
      if (data is Uint8List) {
        return HidInputReport(
          deviceId: deviceId,
          reportId: reportId,
          data: data,
        );
      }
      if (data is List<int>) {
        return HidInputReport(
          deviceId: deviceId,
          reportId: reportId,
          data: Uint8List.fromList(data),
        );
      }
      throw PlatformException(
        code: 'invalid_event',
        message: 'Unexpected input report payload ${data.runtimeType}',
      );
    });
    return _inputReports!;
  }
}
