import 'dart:typed_data';

/// Basic filter used to select HID devices by vendor/product/usage fields.
class HidDeviceFilter {
  const HidDeviceFilter({
    this.vendorId,
    this.productId,
    this.usagePage,
    this.usage,
  });

  final int? vendorId;
  final int? productId;
  final int? usagePage;
  final int? usage;

  Map<String, Object?> toMap() => {
    'vendorId': vendorId,
    'productId': productId,
    'usagePage': usagePage,
    'usage': usage,
  }..removeWhere((_, value) => value == null);

  factory HidDeviceFilter.fromMap(Map<dynamic, dynamic> map) {
    return HidDeviceFilter(
      vendorId: map['vendorId'] as int?,
      productId: map['productId'] as int?,
      usagePage: map['usagePage'] as int?,
      usage: map['usage'] as int?,
    );
  }
}

/// Describes a single HID device.
class HidDeviceInfo {
  const HidDeviceInfo({
    required this.id,
    required this.vendorId,
    required this.productId,
    this.productName,
    this.manufacturerName,
    this.serialNumber,
    this.usagePage,
    this.usage,
    this.interfaceNumber,
    this.busNumber,
    this.deviceAddress,
    this.opened = false,
  });

  /// Unique identifier used to re-open the device (path on desktop, synthetic on web).
  final String id;
  final int vendorId;
  final int productId;
  final String? productName;
  final String? manufacturerName;
  final String? serialNumber;
  final int? usagePage;
  final int? usage;
  final int? interfaceNumber;
  final int? busNumber;
  final int? deviceAddress;
  final bool opened;

  Map<String, Object?> toMap() => {
    'id': id,
    'vendorId': vendorId,
    'productId': productId,
    'productName': productName,
    'manufacturerName': manufacturerName,
    'serialNumber': serialNumber,
    'usagePage': usagePage,
    'usage': usage,
    'interfaceNumber': interfaceNumber,
    'busNumber': busNumber,
    'deviceAddress': deviceAddress,
    'opened': opened,
  }..removeWhere((_, value) => value == null);

  factory HidDeviceInfo.fromMap(Map<dynamic, dynamic> map) {
    return HidDeviceInfo(
      id: map['id'] as String,
      vendorId: map['vendorId'] as int,
      productId: map['productId'] as int,
      productName: map['productName'] as String?,
      manufacturerName: map['manufacturerName'] as String?,
      serialNumber: map['serialNumber'] as String?,
      usagePage: map['usagePage'] as int?,
      usage: map['usage'] as int?,
      interfaceNumber: map['interfaceNumber'] as int?,
      busNumber: map['busNumber'] as int?,
      deviceAddress: map['deviceAddress'] as int?,
      opened: (map['opened'] as bool?) ?? false,
    );
  }
}

/// Input report payload emitted by HID devices.
class HidInputReport {
  const HidInputReport({
    required this.deviceId,
    required this.reportId,
    required this.data,
  });

  final String deviceId;

  /// Report ID supplied separately by the platform HID API.
  final int reportId;

  /// Report payload without the report-ID prefix byte.
  final Uint8List data;
}

/// Wrapper around an opened HID device handle.
class HidDeviceHandle {
  const HidDeviceHandle({required this.deviceId, required this.handle});

  final String deviceId;
  final int handle;
}
