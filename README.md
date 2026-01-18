# usb_hid

Cross-platform USB HID plugin built on platform channels with WebHID support.

## Status

- Web: implemented via WebHID (enumeration, `requestDevice`, open/close, output and feature reports, input report stream). Uses the MDN-documented `navigator.hid` API and reads usage/usagePage from the first collection; `requestDevice` returns the first selected device when the browser returns a list.
- Windows: implemented with Win32 HID APIs (enumeration, open/close, output and feature reports, input report stream).
- macOS: implemented with IOHID (enumeration, open/close, output and feature reports, input report stream).
- Android: implemented with USB host HID (enumeration, permission prompt via `requestDevice`, open/close, output and feature reports, input report stream).
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

### Platform roadmap

- Add native HID enumeration and IO for Windows (Win32/WinRT HID), Android (USB host HID), and macOS (IOHID). The platform channels are already in place (`usb_hid/methods`, `usb_hid/input_reports`).

