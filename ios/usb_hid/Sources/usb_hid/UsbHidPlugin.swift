import DriverKitHidClient
import Flutter
import Foundation

private final class HidHandle {
  let id: Int
  let deviceId: String
  let connection: UInt32
  let info: UsbHidDriverDeviceInfo
  let readQueue: DispatchQueue
  var running = true

  init(id: Int, deviceId: String, connection: UInt32, info: UsbHidDriverDeviceInfo) {
    self.id = id
    self.deviceId = deviceId
    self.connection = connection
    self.info = info
    readQueue = DispatchQueue(label: "usb_hid.driverkit.\(id)", qos: .userInitiated)
  }
}

public final class UsbHidPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var nextHandle = 1
  private var handles: [Int: HidHandle] = [:]
  private let stateQueue = DispatchQueue(label: "usb_hid.driverkit.state")

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = UsbHidPlugin()
    let methods = FlutterMethodChannel(
      name: "usb_hid/methods",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methods)
    let reports = FlutterEventChannel(
      name: "usb_hid/input_reports",
      binaryMessenger: registrar.messenger()
    )
    reports.setStreamHandler(instance)
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isDriverAvailable":
      result(UsbHidDriverIsAvailable())
    case "listDevices":
      result(filteredDevices(arguments: call.arguments).map(deviceMap))
    case "requestDevice":
      result(filteredDevices(arguments: call.arguments).first.map(deviceMap))
    case "openDevice":
      open(arguments: call.arguments, result: result)
    case "closeDevice":
      close(arguments: call.arguments, result: result)
    case "sendOutputReport":
      sendOutput(arguments: call.arguments, result: result)
    case "sendFeatureReport":
      setFeature(arguments: call.arguments, result: result)
    case "getFeatureReport":
      getFeature(arguments: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func copyDevices() -> [UsbHidDriverDeviceInfo] {
    let count = UsbHidDriverCopyDevices(nil, 0)
    guard count > 0 else { return [] }
    var devices = Array(repeating: UsbHidDriverDeviceInfo(), count: count)
    let copied = devices.withUnsafeMutableBufferPointer { buffer in
      UsbHidDriverCopyDevices(buffer.baseAddress, buffer.count)
    }
    return Array(devices.prefix(min(copied, devices.count)))
  }

  private func filteredDevices(arguments: Any?) -> [UsbHidDriverDeviceInfo] {
    guard
      let map = arguments as? [String: Any],
      let filters = map["filters"] as? [[String: Any]],
      !filters.isEmpty
    else { return copyDevices() }
    return copyDevices().filter { device in
      filters.contains { filter in
        if let vendor = (filter["vendorId"] as? NSNumber)?.uint16Value,
           vendor != device.vendorId { return false }
        if let product = (filter["productId"] as? NSNumber)?.uint16Value,
           product != device.productId { return false }
        // USBDriverKit provides raw interface access. Usage metadata is not
        // available unless the host extension parses a HID report descriptor.
        if filter["usagePage"] != nil || filter["usage"] != nil { return false }
        return true
      }
    }
  }

  private func deviceId(_ info: UsbHidDriverDeviceInfo) -> String {
    "driverkit-\(String(info.registryEntryId, radix: 16))"
  }

  private func deviceMap(_ info: UsbHidDriverDeviceInfo) -> [String: Any] {
    [
      "id": deviceId(info),
      "vendorId": Int(info.vendorId),
      "productId": Int(info.productId),
      "productName": "Espressif USB HID",
      "manufacturerName": "Espressif",
      "serialNumber": "",
      "interfaceNumber": Int(info.interfaceNumber),
      "opened": stateQueue.sync {
        handles.values.contains { $0.info.registryEntryId == info.registryEntryId }
      },
    ]
  }

  private func open(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let map = arguments as? [String: Any],
      let device = map["device"] as? [String: Any],
      let id = device["id"] as? String,
      let registryId = parseDeviceId(id),
      let info = copyDevices().first(where: { $0.registryEntryId == registryId })
    else {
      result(pluginError("DEVICE_NOT_FOUND", "Espressif HID device is not available"))
      return
    }
    var connection: UInt32 = 0
    let openResult = UsbHidDriverOpen(registryId, &connection)
    guard openResult == 0 else {
      result(driverError("OPEN_FAILED", "Could not open DriverKit HID user client", openResult))
      return
    }
    let handle: HidHandle = stateQueue.sync {
      let id = nextHandle
      nextHandle += 1
      let created = HidHandle(
        id: id,
        deviceId: self.deviceId(info),
        connection: connection,
        info: info
      )
      handles[id] = created
      return created
    }
    startReading(handle)
    result(["handle": handle.id])
  }

  private func startReading(_ handle: HidHandle) {
    handle.readQueue.async { [weak self, weak handle] in
      guard let self, let handle else { return }
      var buffer = [UInt8](
        repeating: 0,
        count: max(Int(handle.info.maxInputPacketSize), 64)
      )
      while self.stateQueue.sync(execute: { handle.running }) {
        var bytesRead: UInt32 = 0
        let readResult = buffer.withUnsafeMutableBytes { rawBuffer in
          UsbHidDriverRead(
            handle.connection,
            rawBuffer.bindMemory(to: UInt8.self).baseAddress,
            UInt32(rawBuffer.count),
            &bytesRead
          )
        }
        if readResult != 0 { break }
        if bytesRead > 0 {
          self.emit([
            "deviceId": handle.deviceId,
            "reportId": 0,
            "data": FlutterStandardTypedData(
              bytes: Data(buffer.prefix(Int(bytesRead)))
            ),
          ])
        }
      }
    }
  }

  private func close(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let map = arguments as? [String: Any],
      let id = (map["handle"] as? NSNumber)?.intValue
    else {
      result(argumentError("handle is required"))
      return
    }
    let handle = stateQueue.sync { () -> HidHandle? in
      guard let removed = handles.removeValue(forKey: id) else { return nil }
      removed.running = false
      return removed
    }
    if let handle { UsbHidDriverClose(handle.connection) }
    result(nil)
  }

  private func sendOutput(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let map = arguments as? [String: Any],
      let handle = handle(from: map),
      let typedData = map["data"] as? FlutterStandardTypedData
    else {
      result(argumentError("handle and data are required"))
      return
    }
    let reportId = (map["reportId"] as? NSNumber)?.uint8Value ?? 0
    var payload = Data()
    if reportId != 0 { payload.append(reportId) }
    payload.append(typedData.data)
    var bytesWritten: UInt32 = 0
    let writeResult = payload.withUnsafeBytes { rawBuffer in
      UsbHidDriverWrite(
        handle.connection,
        rawBuffer.bindMemory(to: UInt8.self).baseAddress,
        UInt32(rawBuffer.count),
        &bytesWritten
      )
    }
    if writeResult == 0 {
      result(Int(bytesWritten) - (reportId == 0 ? 0 : 1))
    } else {
      result(driverError("WRITE_FAILED", "HID output report failed", writeResult))
    }
  }

  private func setFeature(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let map = arguments as? [String: Any],
      let handle = handle(from: map),
      let typedData = map["data"] as? FlutterStandardTypedData
    else {
      result(argumentError("handle and data are required"))
      return
    }
    let reportId = (map["reportId"] as? NSNumber)?.uint8Value ?? 0
    let featureResult = typedData.data.withUnsafeBytes { rawBuffer in
      UsbHidDriverSetFeature(
        handle.connection,
        reportId,
        rawBuffer.bindMemory(to: UInt8.self).baseAddress,
        UInt32(rawBuffer.count)
      )
    }
    completeVoid(featureResult, code: "FEATURE_FAILED", result: result)
  }

  private func getFeature(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let map = arguments as? [String: Any],
      let handle = handle(from: map),
      let length = (map["length"] as? NSNumber)?.intValue,
      length > 0
    else {
      result(argumentError("handle and positive length are required"))
      return
    }
    let reportId = (map["reportId"] as? NSNumber)?.uint8Value ?? 0
    var bytes = [UInt8](repeating: 0, count: length)
    var bytesRead: UInt32 = 0
    let featureResult = bytes.withUnsafeMutableBytes { rawBuffer in
      UsbHidDriverGetFeature(
        handle.connection,
        reportId,
        rawBuffer.bindMemory(to: UInt8.self).baseAddress,
        UInt32(rawBuffer.count),
        &bytesRead
      )
    }
    if featureResult == 0 {
      result(FlutterStandardTypedData(bytes: Data(bytes.prefix(Int(bytesRead)))))
    } else {
      result(driverError("FEATURE_FAILED", "HID feature report failed", featureResult))
    }
  }

  private func handle(from map: [String: Any]) -> HidHandle? {
    guard let id = (map["handle"] as? NSNumber)?.intValue else { return nil }
    return stateQueue.sync { handles[id] }
  }

  private func parseDeviceId(_ id: String) -> UInt64? {
    guard id.hasPrefix("driverkit-") else { return nil }
    return UInt64(id.dropFirst("driverkit-".count), radix: 16)
  }

  private func completeVoid(
    _ callResult: Int32,
    code: String,
    result: @escaping FlutterResult
  ) {
    if callResult == 0 {
      result(nil)
    } else {
      result(driverError(code, "DriverKit operation failed", callResult))
    }
  }

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.eventSink?(event) }
  }

  private func argumentError(_ message: String) -> FlutterError {
    pluginError("INVALID_ARGUMENT", message)
  }

  private func pluginError(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  private func driverError(_ code: String, _ message: String, _ value: Int32) -> FlutterError {
    FlutterError(
      code: code,
      message: String(format: "%@ (IOReturn 0x%08X)", message, UInt32(bitPattern: value)),
      details: value
    )
  }
}
