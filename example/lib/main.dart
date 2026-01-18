import 'dart:async';

import 'package:flutter/material.dart';
import 'package:usb_hid/usb_hid.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _usbHidPlugin = UsbHid();

  List<HidDeviceInfo> _devices = const [];
  HidDeviceInfo? _requested;
  HidDevice? _session;
  StreamSubscription<HidInputReport>? _inputSub;
  String _lastReport = 'No reports yet';

  @override
  void initState() {
    super.initState();
    _refreshDevices();
  }

  Future<void> _refreshDevices() async {
    final devices = await _usbHidPlugin.listDevices();
    if (!mounted) return;
    setState(() => _devices = devices);
  }

  Future<void> _requestDevice() async {
    final result = await _usbHidPlugin.requestDevice(
      filters: const [HidDeviceFilter()],
    );
    if (!mounted) return;
    setState(() => _requested = result);
    if (result == null) return;

    // Attempt to open the device and listen for input reports as a demonstration.
    _session = await _usbHidPlugin.openDevice(result);
    await _inputSub?.cancel();
    _inputSub = _session!.inputReports.listen((event) {
      setState(() {
        _lastReport = 'device=${event.deviceId} report=${event.reportId} length=${event.data.length}';
      });
    });
  }

  @override
  void dispose() {
    _inputSub?.cancel();
    _session?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: _requestDevice,
                child: const Text('Request device'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _refreshDevices,
                child: const Text('Refresh devices'),
              ),
              const SizedBox(height: 16),
              Text('Devices (${_devices.length}):'),
              ..._devices
                  .map(
                    (d) => Text(
                      '${d.id} v=${d.vendorId.toRadixString(16)} p=${d.productId.toRadixString(16)}',
                      textAlign: TextAlign.center,
                    ),
                  ),
              const SizedBox(height: 16),
              Text('Requested: ${_requested?.id ?? 'none'}'),
              const SizedBox(height: 8),
              Text(_lastReport),
            ],
          ),
        ),
      ),
    );
  }
}
