# usb_hid

Cross-platform USB HID plugin built on platform channels with WebHID support.

## Status

- Web: implemented via WebHID (enumeration, `requestDevice`, open/close, output and feature reports, input report stream). Uses the MDN-documented `navigator.hid` API and reads usage/usagePage from the first collection; `requestDevice` returns the first selected device when the browser returns a list.
- Windows: implemented with Win32 HID APIs (enumeration, open/close, output and feature reports, input report stream).
- macOS: implemented with IOHID (enumeration, open/close, output and feature reports, input report stream).
- Android: implemented with USB host HID (enumeration, permission prompt via `requestDevice`, open/close, output and feature reports, input report stream).
- iPadOS 16+: implemented as a Swift package using an app-embedded
  USBDriverKit extension and IOKit user client. USBDriverKit on iPadOS requires
  an M-series iPad and Apple-approved DriverKit entitlements for the app's USB
  vendor.
- Linux: implemented with hidapi (hidraw) for enumeration, open/close, output and feature reports, input report stream. Requires `libhidapi-hidraw` (or distro equivalent) at build time.

## Usage

```dart
final hid = UsbHid();

// Request a device (required on Web; shows the browser prompt)
final device = await hid.requestDevice(filters: const [HidDeviceFilter(vendorId: 0x1234)]);
if (device == null) return;

// Open and listen for input reports
final session = await hid.openDevice(device);
final sub = session.inputReports.listen((report) {
	debugPrint('report ${report.reportId} length=${report.data.length}');
});

// Send an output report
await session.sendOutputReport(Uint8List.fromList([0x00, 0x01]));

// When done
await session.close();
await sub.cancel();
```

### Web notes

- `requestDevice` must be called in response to a user gesture (e.g., button tap) or the browser will reject the prompt.
- `listDevices` returns already-permitted devices without prompting.
- Input reports arrive via the `inputReports` stream; output and feature reports are supported.

### iPadOS notes

- Swift Package Manager integration must be enabled in the Flutter app.
- The host app must embed and provision a USBDriverKit extension. The package
  connects to the `DaliMasterEspressifUsbDriver` user-client service; hosts can
  adapt that name in `DriverKitHidClient.c` for their own extension.
- Add `com.apple.developer.driverkit.communicates-with-drivers` to the app
  entitlement. The driver requires `com.apple.developer.driverkit` and an
  approved `com.apple.developer.driverkit.transport.usb` entitlement.
- `UsbHid().isDriverAvailable()` reports whether a compatible HID driver
  service loaded. Device access on iPadOS is entitlement-based, so
  `requestDevice` selects the first matching loaded device without an extra
  picker.
- A single host driver can expose serial or HID interfaces through the shared
  protocol. The DaliMaster app signs its driver only for Espressif vendor ID
  `0x303A`; it does not claim DALI USB HID or KNX adapter vendor IDs.
