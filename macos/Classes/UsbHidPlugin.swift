import Cocoa
import FlutterMacOS
import IOKit.hid

private struct HidDeviceInfo {
  let device: IOHIDDevice
  let id: String
  let vendorId: Int
  let productId: Int
  let usagePage: Int?
  let usage: Int?
  let productName: String?
  let manufacturerName: String?
  let serialNumber: String?
}

private final class OpenHandle {
  let handleId: Int
  let info: HidDeviceInfo
  let inputReportLength: Int
  var buffer: UnsafeMutablePointer<UInt8>?

  init(handleId: Int, info: HidDeviceInfo, inputReportLength: Int) {
    self.handleId = handleId
    self.info = info
    self.inputReportLength = inputReportLength
  }
}

public class UsbHidPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private let manager: IOHIDManager
  private var nextHandleId: Int = 1
  private var openHandles: [Int: OpenHandle] = [:]
  private let queue = DispatchQueue(label: "com.dalimaster.usb_hid")

  override init() {
    manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    super.init()
    IOHIDManagerSetDeviceMatching(manager, nil)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
  }

  deinit {
    stopAll()
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(name: "usb_hid/methods", binaryMessenger: registrar.messenger)
    let eventChannel = FlutterEventChannel(name: "usb_hid/input_reports", binaryMessenger: registrar.messenger)

    let instance = UsbHidPlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listDevices":
      result(listDevices(filters: call.arguments))
    case "requestDevice":
      result(requestDevice(filters: call.arguments))
    case "openDevice":
      openDevice(args: call.arguments, result: result)
    case "closeDevice":
      closeDevice(args: call.arguments, result: result)
    case "sendOutputReport":
      sendReport(args: call.arguments, type: kIOHIDReportTypeOutput, result: result)
    case "sendFeatureReport":
      sendReport(args: call.arguments, type: kIOHIDReportTypeFeature, result: result)
    case "getFeatureReport":
      getFeatureReport(args: call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func listDevices(filters: Any?) -> Any {
    let filterList = (filters as? [String: Any])?["filters"] as? [Any]
    let devices = enumerateDevices()
    let filtered = filterList == nil ? devices : devices.filter { matchesFilters(info: $0, filters: filterList!) }
    return filtered.map { encodeDevice($0, opened: false) }
  }

  private func requestDevice(filters: Any?) -> Any? {
    let filterList = (filters as? [String: Any])?["filters"] as? [Any]
    let devices = enumerateDevices()
    let filtered = filterList == nil ? devices : devices.filter { matchesFilters(info: $0, filters: filterList!) }
    return filtered.first.map { encodeDevice($0, opened: false) }
  }

  private func openDevice(args: Any?, result: @escaping FlutterResult) {
    guard
      let map = args as? [String: Any],
      let deviceMap = map["device"] as? [String: Any],
      let id = deviceMap["id"] as? String
    else {
      result(FlutterError(code: "invalid_args", message: "device missing", details: nil))
      return
    }

    guard let target = enumerateDevices().first(where: { $0.id == id }) else {
      result(FlutterError(code: "not_found", message: "device not found", details: nil))
      return
    }

    let status = IOHIDDeviceOpen(target.device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    guard status == kIOReturnSuccess else {
      result(FlutterError(code: "open_failed", message: "IOHIDDeviceOpen failed", details: status))
      return
    }

    IOHIDDeviceScheduleWithRunLoop(target.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    let handleId = nextHandleId
    nextHandleId += 1
    let inputLen = inputReportLength(for: target.device)
    let handle = OpenHandle(handleId: handleId, info: target, inputReportLength: inputLen)
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputLen)
    buffer.initialize(repeating: 0, count: inputLen)
    handle.buffer = buffer

    IOHIDDeviceRegisterInputReportCallback(target.device, buffer, inputLen, { context, resultCode, sender, _, reportId, report, reportLen in
      guard let context = context else { return }
      let plugin = Unmanaged<UsbHidPlugin>.fromOpaque(context).takeUnretainedValue()
      let device = sender.map { unsafeBitCast($0, to: IOHIDDevice.self) }
      let deviceId = plugin.identifier(for: device)
      let data = Data(bytes: report, count: Int(reportLen))
      plugin.emitInputReport(deviceId: deviceId, reportId: Int(reportId), data: data)
    }, Unmanaged.passUnretained(self).toOpaque())

    openHandles[handleId] = handle
    result(["handle": handleId])
  }

  private func closeDevice(args: Any?, result: @escaping FlutterResult) {
    guard let map = args as? [String: Any], let handleId = map["handle"] as? Int else {
      result(FlutterError(code: "invalid_args", message: "handle missing", details: nil))
      return
    }
    if let handle = openHandles.removeValue(forKey: handleId) {
      if let buffer = handle.buffer {
        buffer.deallocate()
      }
      IOHIDDeviceUnscheduleFromRunLoop(handle.info.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
      IOHIDDeviceClose(handle.info.device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    result(nil)
  }

  private func sendReport(args: Any?, type: IOHIDReportType, result: @escaping FlutterResult) {
    guard
      let map = args as? [String: Any],
      let handleId = map["handle"] as? Int,
      let reportId = map["reportId"] as? Int,
      let data = map["data"] as? FlutterStandardTypedData
    else {
      result(FlutterError(code: "invalid_args", message: "payload missing", details: nil))
      return
    }

    guard let handle = openHandles[handleId] else {
      result(FlutterError(code: "not_open", message: "handle not found", details: nil))
      return
    }

    var buffer = Data([UInt8(reportId)])
    buffer.append(data.data)
    let status = buffer.withUnsafeBytes { ptr -> IOReturn in
      guard let baseAddress = ptr.bindMemory(to: UInt8.self).baseAddress else {
      return kIOReturnBadArgument
      }
      return IOHIDDeviceSetReport(handle.info.device, type, CFIndex(reportId), baseAddress, ptr.count)
    }
    if status != kIOReturnSuccess {
      result(FlutterError(code: "write_failed", message: "IOHIDDeviceSetReport failed", details: status))
    } else {
      result(type == kIOHIDReportTypeOutput ? buffer.count : nil)
    }
  }

  private func getFeatureReport(args: Any?, result: @escaping FlutterResult) {
    guard
      let map = args as? [String: Any],
      let handleId = map["handle"] as? Int,
      let reportId = map["reportId"] as? Int,
      let length = map["length"] as? Int
    else {
      result(FlutterError(code: "invalid_args", message: "payload missing", details: nil))
      return
    }

    guard let handle = openHandles[handleId] else {
      result(FlutterError(code: "not_open", message: "handle not found", details: nil))
      return
    }

    var buffer = Data(count: max(length + 1, 1))
    buffer[0] = UInt8(reportId & 0xFF)
    var reportLength = buffer.count
    let status = buffer.withUnsafeMutableBytes { ptr -> IOReturn in
      guard let baseAddress = ptr.bindMemory(to: UInt8.self).baseAddress else {
      return kIOReturnBadArgument
      }
      return IOHIDDeviceGetReport(handle.info.device, kIOHIDReportTypeFeature, CFIndex(reportId), baseAddress, &reportLength)
    }
    if status != kIOReturnSuccess {
      result(nil)
    } else {
      buffer.count = reportLength
      result(FlutterStandardTypedData(bytes: buffer))
    }
  }

  private func enumerateDevices() -> [HidDeviceInfo] {
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    return devices.compactMap { buildInfo(device: $0) }
  }

  private func buildInfo(device: IOHIDDevice) -> HidDeviceInfo? {
    let vendorId = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
    let productId = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
    let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int
    let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
    let manufacturerName = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
    let serialNumber = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
    let locationId = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int) ?? 0
    let id = "macos-\(vendorId)-\(productId)-\(locationId)"

    return HidDeviceInfo(
      device: device,
      id: id,
      vendorId: vendorId,
      productId: productId,
      usagePage: usagePage,
      usage: usage,
      productName: productName,
      manufacturerName: manufacturerName,
      serialNumber: serialNumber
    )
  }

  private func encodeDevice(_ info: HidDeviceInfo, opened: Bool) -> [String: Any] {
    var map: [String: Any] = [
      "id": info.id,
      "vendorId": info.vendorId,
      "productId": info.productId,
      "opened": opened
    ]
    if let usagePage = info.usagePage { map["usagePage"] = usagePage }
    if let usage = info.usage { map["usage"] = usage }
    if let productName = info.productName { map["productName"] = productName }
    if let manufacturerName = info.manufacturerName { map["manufacturerName"] = manufacturerName }
    if let serialNumber = info.serialNumber { map["serialNumber"] = serialNumber }
    return map
  }

  private func matchesFilters(info: HidDeviceInfo, filters: [Any]) -> Bool {
    for entry in filters {
      guard let map = entry as? [String: Any] else { continue }
      if let vendorId = map["vendorId"] as? Int, vendorId != info.vendorId { continue }
      if let productId = map["productId"] as? Int, productId != info.productId { continue }
      if let usagePage = map["usagePage"] as? Int, usagePage != info.usagePage { continue }
      if let usage = map["usage"] as? Int, usage != info.usage { continue }
      return true
    }
    return filters.isEmpty
  }

  private func inputReportLength(for device: IOHIDDevice) -> Int {
    if let number = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int { return max(1, number) }
    return 64
  }

  private func emitInputReport(deviceId: String, reportId: Int, data: Data) {
    guard let sink = eventSink else { return }
    let map: [String: Any] = [
      "deviceId": deviceId,
      "reportId": reportId,
      "data": FlutterStandardTypedData(bytes: data)
    ]
    sink(map)
  }

  private func identifier(for device: IOHIDDevice?) -> String {
    guard let device = device else { return "unknown" }
    let vendorId = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
    let productId = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    let locationId = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int) ?? 0
    return "macos-\(vendorId)-\(productId)-\(locationId)"
  }

  private func stopAll() {
    for (_, handle) in openHandles {
      if let buffer = handle.buffer {
        buffer.deallocate()
      }
      IOHIDDeviceUnscheduleFromRunLoop(handle.info.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
      IOHIDDeviceClose(handle.info.device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    openHandles.removeAll()
  }
}
