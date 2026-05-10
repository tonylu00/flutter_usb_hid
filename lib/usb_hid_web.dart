// ignore: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

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

  JSObject? get _hid =>
      globalContext.getProperty<JSObject?>('navigator'.toJS)?.getProperty<JSObject?>('hid'.toJS);

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
    final devices = await _callMethod<JSPromise<JSArray<JSObject>>>(_hid!, 'getDevices').toDart;

    final infos = devices.toDart.map(_deviceInfoFromJs).toList();
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
    final result = await _callMethod<JSPromise<JSAny?>>(_hid!, 'requestDevice', [
      <String, Object?>{'filters': jsFilters}.jsify(),
    ]).toDart;

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

    final opened = _getBool(jsDevice, 'opened') ?? false;
    if (!opened) {
      await _callMethod<JSPromise<JSAny?>>(jsDevice, 'open').toDart;
    }

    final handleId = _nextHandle++;
    final listener = ((JSAny event) {
      final eventObject = event as JSObject;
      final reportId = _getInt(eventObject, 'reportId') ?? 0;
      final dataView = eventObject.getProperty<JSObject?>('data'.toJS);
      if (dataView == null) {
        return;
      }
      final payload = _dataViewToBytes(dataView);
      _inputController.add(HidInputReport(deviceId: device.id, reportId: reportId, data: payload));
    }).toJS;

    _callMethod<JSAny?>(jsDevice, 'addEventListener', ['inputreport'.toJS, listener]);
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
    _callMethod<JSAny?>(entry.jsDevice, 'removeEventListener', [
      'inputreport'.toJS,
      entry.inputListener,
    ]);
    await _callMethod<JSPromise<JSAny?>>(entry.jsDevice, 'close').toDart;
  }

  @override
  Future<int> sendOutputReport(HidDeviceHandle handle, int reportId, Uint8List data) async {
    _assertHidAvailable();
    final entry = _openDevices[handle.handle];
    if (entry == null) {
      throw PlatformException(code: 'not_open', message: 'Device not open');
    }
    await _callMethod<JSPromise<JSAny?>>(entry.jsDevice, 'sendReport', [
      reportId.toJS,
      data.toJS,
    ]).toDart;
    return data.length;
  }

  @override
  Future<void> sendFeatureReport(HidDeviceHandle handle, int reportId, Uint8List data) async {
    _assertHidAvailable();
    final entry = _openDevices[handle.handle];
    if (entry == null) {
      throw PlatformException(code: 'not_open', message: 'Device not open');
    }
    await _callMethod<JSPromise<JSAny?>>(entry.jsDevice, 'sendFeatureReport', [
      reportId.toJS,
      data.toJS,
    ]).toDart;
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
    final dataView = await _callMethod<JSPromise<JSObject?>>(
      entry.jsDevice,
      'receiveFeatureReport',
      [reportId.toJS],
    ).toDart;
    if (dataView == null) {
      return null;
    }
    final payload = _dataViewToBytes(dataView);
    return payload.length >= reportLength ? payload.sublist(0, reportLength) : payload;
  }

  Future<JSObject?> _findDevice(String id) async {
    final devices = await _callMethod<JSPromise<JSArray<JSObject>>>(_hid!, 'getDevices').toDart;
    for (final device in devices.toDart) {
      if (_deviceId(device) == id) {
        return device;
      }
    }
    return null;
  }

  HidDeviceInfo _deviceInfoFromJs(JSObject jsDevice) {
    final vendorId = _getInt(jsDevice, 'vendorId') ?? 0;
    final productId = _getInt(jsDevice, 'productId') ?? 0;
    final productName = _getString(jsDevice, 'productName');
    final manufacturerName = _getString(jsDevice, 'manufacturerName');
    final serialNumber = _getString(jsDevice, 'serialNumber');
    final usageInfo = _primaryUsageFromCollections(jsDevice);
    final opened = _getBool(jsDevice, 'opened') ?? false;

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

  String _deviceId(JSObject jsDevice) {
    final vendorId = _getInt(jsDevice, 'vendorId') ?? 0;
    final productId = _getInt(jsDevice, 'productId') ?? 0;
    final serialNumber = _getString(jsDevice, 'serialNumber');
    final productName = _getString(jsDevice, 'productName');
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

  Uint8List _dataViewToBytes(JSObject dataView) {
    final length = _getInt(dataView, 'byteLength') ?? 0;
    final buffer = Uint8List(length);
    for (var i = 0; i < length; i++) {
      final value = _callMethod<JSNumber>(dataView, 'getUint8', [i.toJS]);
      buffer[i] = value.toDartInt;
    }
    return buffer;
  }

  JSObject? _firstDeviceFromResult(JSAny? result) {
    if (result == null) return null;
    if (result.isA<JSArray<JSObject>>()) {
      final devices = (result as JSArray<JSObject>).toDart;
      return devices.isEmpty ? null : devices.first;
    }
    return result as JSObject;
  }

  (int?, int?) _primaryUsageFromCollections(JSObject jsDevice) {
    final collections = jsDevice.getProperty<JSArray<JSObject>?>('collections'.toJS);
    final collectionList = collections?.toDart;
    if (collectionList != null && collectionList.isNotEmpty) {
      final first = collectionList.first;
      return (_getInt(first, 'usagePage'), _getInt(first, 'usage'));
    }
    return (null, null);
  }

  R _callMethod<R extends JSAny?>(
    JSObject target,
    String method, [
    List<JSAny?> args = const <JSAny?>[],
  ]) {
    return target.callMethodVarArgs<R>(method.toJS, args);
  }

  int? _getInt(JSObject target, String property) {
    final value = target.getProperty<JSNumber?>(property.toJS);
    if (value == null) {
      return null;
    }
    return value.toDartInt;
  }

  String? _getString(JSObject target, String property) {
    final value = target.getProperty<JSString?>(property.toJS);
    return value?.toDart;
  }

  bool? _getBool(JSObject target, String property) {
    final value = target.getProperty<JSBoolean?>(property.toJS);
    return value?.toDart;
  }
}

class _WebHidDeviceHandle {
  _WebHidDeviceHandle({
    required this.deviceId,
    required this.jsDevice,
    required this.inputListener,
  });

  final String deviceId;
  final JSObject jsDevice;
  final JSFunction inputListener;
}
