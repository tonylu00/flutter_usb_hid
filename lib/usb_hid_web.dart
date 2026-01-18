// ignore: avoid_web_libraries_in_flutter
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
// ignore: deprecated_member_use
import 'package:js/js_util.dart' as js_util;
import 'package:web/web.dart' as web;

import 'src/types.dart';
import 'usb_hid_platform_interface.dart';

class UsbHidWeb extends UsbHidPlatform {
  UsbHidWeb();

  static void registerWith(Registrar registrar) {
    UsbHidPlatform.instance = UsbHidWeb();
  }

  final _inputController = StreamController<HidInputReport>.broadcast();
  final _openDevices = <int, _WebHidDeviceHandle>{};
  int _nextHandle = 1;

  dynamic get _hid => js_util.getProperty(web.window.navigator, 'hid');

  void _assertHidAvailable() {
    if (_hid == null) {
      throw PlatformException(
        code: 'webhid_unavailable',
        message: 'This browser does not expose navigator.hid',
      );
    }
  }

  @override
  Stream<HidInputReport> get inputReports => _inputController.stream;

  @override
  Future<List<HidDeviceInfo>> listDevices({List<HidDeviceFilter>? filters}) async {
    _assertHidAvailable();
    final devices = await js_util.promiseToFuture<List<dynamic>>(
      js_util.callMethod(_hid, 'getDevices', const []),
    );

    final infos = devices.map((dynamic entry) => _deviceInfoFromJs(entry as Object)).toList();
    if (filters == null || filters.isEmpty) {
      return infos;
    }
    return infos.where((device) => _matchesFilters(device, filters)).toList();
  }

  @override
  Future<HidDeviceInfo?> requestDevice({required List<HidDeviceFilter> filters}) async {
    _assertHidAvailable();
    final jsFilters = filters
        .map((f) => f.toMap()..removeWhere((_, value) => value == null))
        .toList();
    final result = await js_util.promiseToFuture<Object?>(
      js_util.callMethod(_hid, 'requestDevice', [
        {'filters': jsFilters},
      ]),
    );

    final selected = _firstDeviceFromResult(result);
    if (selected == null) {
      return null;
    }
    return _deviceInfoFromJs(selected);
  }

  @override
  Future<HidDeviceHandle> openDevice(HidDeviceInfo device) async {
    _assertHidAvailable();
    final jsDevice = await _findDevice(device.id);
    if (jsDevice == null) {
      throw PlatformException(
        code: 'device_not_found',
        message: 'Device ${device.id} is not available',
      );
    }

    final opened = js_util.getProperty<bool?>(jsDevice, 'opened') ?? false;
    if (!opened) {
      await js_util.promiseToFuture<void>(js_util.callMethod(jsDevice, 'open', const []));
    }

    final handleId = _nextHandle++;
    final listener = js_util.allowInterop((dynamic event) {
      final reportId = js_util.getProperty<int?>(event, 'reportId') ?? 0;
      final dataView = js_util.getProperty<Object?>(event, 'data');
      if (dataView == null) {
        return;
      }
      final payload = _dataViewToBytes(dataView);
      _inputController.add(HidInputReport(deviceId: device.id, reportId: reportId, data: payload));
    });

    js_util.callMethod(jsDevice, 'addEventListener', ['inputreport', listener]);
    _openDevices[handleId] = _WebHidDeviceHandle(
      deviceId: device.id,
      jsDevice: jsDevice,
      inputListener: listener,
    );
    return HidDeviceHandle(deviceId: device.id, handle: handleId);
  }

  @override
  Future<void> closeDevice(HidDeviceHandle handle) async {
    _assertHidAvailable();
    final entry = _openDevices.remove(handle.handle);
    if (entry == null) {
      return;
    }
    js_util.callMethod(entry.jsDevice, 'removeEventListener', ['inputreport', entry.inputListener]);
    await js_util.promiseToFuture<void>(js_util.callMethod(entry.jsDevice, 'close', const []));
  }

  @override
  Future<int> sendOutputReport(HidDeviceHandle handle, int reportId, Uint8List data) async {
    _assertHidAvailable();
    final entry = _openDevices[handle.handle];
    if (entry == null) {
      throw PlatformException(code: 'not_open', message: 'Device not open');
    }
    final jsData = js_util.callConstructor(
      js_util.getProperty(js_util.globalThis, 'Uint8Array') as Object,
      [data],
    );
    await js_util.promiseToFuture<void>(
      js_util.callMethod(entry.jsDevice, 'sendReport', [reportId, jsData]),
    );
    return data.length;
  }

  @override
  Future<void> sendFeatureReport(HidDeviceHandle handle, int reportId, Uint8List data) async {
    _assertHidAvailable();
    final entry = _openDevices[handle.handle];
    if (entry == null) {
      throw PlatformException(code: 'not_open', message: 'Device not open');
    }
    final jsData = js_util.callConstructor(
      js_util.getProperty(js_util.globalThis, 'Uint8Array') as Object,
      [data],
    );
    await js_util.promiseToFuture<void>(
      js_util.callMethod(entry.jsDevice, 'sendFeatureReport', [reportId, jsData]),
    );
  }

  @override
  Future<Uint8List?> getFeatureReport(
    HidDeviceHandle handle,
    int reportId,
    int reportLength,
  ) async {
    _assertHidAvailable();
    final entry = _openDevices[handle.handle];
    if (entry == null) {
      throw PlatformException(code: 'not_open', message: 'Device not open');
    }
    final dataView = await js_util.promiseToFuture<Object?>(
      js_util.callMethod(entry.jsDevice, 'receiveFeatureReport', [reportId]),
    );
    if (dataView == null) {
      return null;
    }
    final payload = _dataViewToBytes(dataView);
    return payload.length >= reportLength ? payload.sublist(0, reportLength) : payload;
  }

  Future<Object?> _findDevice(String id) async {
    final devices = await js_util.promiseToFuture<List<dynamic>>(
      js_util.callMethod(_hid, 'getDevices', const []),
    );
    for (final device in devices) {
      if (_deviceId(device) == id) {
        return device;
      }
    }
    return null;
  }

  HidDeviceInfo _deviceInfoFromJs(Object jsDevice) {
    final vendorId = js_util.getProperty<int?>(jsDevice, 'vendorId') ?? 0;
    final productId = js_util.getProperty<int?>(jsDevice, 'productId') ?? 0;
    final productName = js_util.getProperty<String?>(jsDevice, 'productName');
    final manufacturerName = js_util.getProperty<String?>(jsDevice, 'manufacturerName');
    final serialNumber = js_util.getProperty<String?>(jsDevice, 'serialNumber');
    final usageInfo = _primaryUsageFromCollections(jsDevice);
    final opened = js_util.getProperty<bool?>(jsDevice, 'opened') ?? false;

    return HidDeviceInfo(
      id: _deviceId(jsDevice),
      vendorId: vendorId,
      productId: productId,
      productName: productName,
      manufacturerName: manufacturerName,
      serialNumber: serialNumber,
      usagePage: usageInfo.$1,
      usage: usageInfo.$2,
      opened: opened,
    );
  }

  String _deviceId(Object jsDevice) {
    final vendorId = js_util.getProperty<int?>(jsDevice, 'vendorId') ?? 0;
    final productId = js_util.getProperty<int?>(jsDevice, 'productId') ?? 0;
    final serialNumber = js_util.getProperty<String?>(jsDevice, 'serialNumber');
    final productName = js_util.getProperty<String?>(jsDevice, 'productName');
    return 'web-$vendorId-$productId-${serialNumber ?? productName ?? 'unknown'}';
  }

  bool _matchesFilters(HidDeviceInfo device, List<HidDeviceFilter> filters) {
    return filters.any((filter) {
      final matchesVendor = filter.vendorId == null || filter.vendorId == device.vendorId;
      final matchesProduct = filter.productId == null || filter.productId == device.productId;
      final matchesUsagePage = filter.usagePage == null || filter.usagePage == device.usagePage;
      final matchesUsage = filter.usage == null || filter.usage == device.usage;
      return matchesVendor && matchesProduct && matchesUsagePage && matchesUsage;
    });
  }

  Uint8List _dataViewToBytes(Object dataView) {
    final length = js_util.getProperty<int?>(dataView, 'byteLength') ?? 0;
    final buffer = Uint8List(length);
    for (var i = 0; i < length; i++) {
      final value = js_util.callMethod<num>(dataView, 'getUint8', [i]);
      buffer[i] = value.toInt();
    }
    return buffer;
  }

  Object? _firstDeviceFromResult(Object? result) {
    if (result == null) return null;
    if (result is List && result.isNotEmpty) {
      return result.first;
    }
    return result;
  }

  (int?, int?) _primaryUsageFromCollections(Object jsDevice) {
    final collections = js_util.getProperty<Object?>(jsDevice, 'collections');
    if (collections is List && collections.isNotEmpty) {
      final first = collections.first;
      if (first != null) {
        final usagePage = js_util.getProperty<num?>(first, 'usagePage');
        final usage = js_util.getProperty<num?>(first, 'usage');
        return (usagePage?.toInt(), usage?.toInt());
      }
    }
    return (null, null);
  }
}

class _WebHidDeviceHandle {
  _WebHidDeviceHandle({
    required this.deviceId,
    required this.jsDevice,
    required this.inputListener,
  });

  final String deviceId;
  final Object jsDevice;
  final Object inputListener;
}
