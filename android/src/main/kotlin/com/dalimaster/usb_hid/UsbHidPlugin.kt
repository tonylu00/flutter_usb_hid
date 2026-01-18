package com.dalimaster.usb_hid

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class UsbHidPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware {

    companion object {
        private const val ACTION_USB_PERMISSION = "com.dalimaster.usb_hid.USB_PERMISSION"
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private lateinit var usbManager: UsbManager

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private data class OpenHandle(
        val handleId: Int,
        val device: UsbDevice,
        val connection: UsbDeviceConnection,
        val iface: UsbInterface,
        val inEndpoint: UsbEndpoint?,
        val outEndpoint: UsbEndpoint?,
        val running: AtomicBoolean = AtomicBoolean(true),
        var readerThread: Thread? = null,
    )

    private var nextHandleId = 1
    private val openHandles = mutableMapOf<Int, OpenHandle>()
    private val handlesLock = Any()

    private data class PendingPermission(val device: UsbDevice, val result: Result)
    private var pendingPermission: PendingPermission? = null
    private val permissionLock = Any()

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_USB_PERMISSION) return
            val device = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE) ?: return
            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            var pending: PendingPermission?
            synchronized(permissionLock) {
                pending = pendingPermission
                if (pending != null && pending!!.device.deviceId == device.deviceId) {
                    pendingPermission = null
                } else {
                    pending = null
                }
            }
            pending?.let {
                if (granted) {
                    it.result.success(encodeDevice(device, false))
                } else {
                    it.result.success(null)
                }
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager

        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "usb_hid/methods")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "usb_hid/input_reports")
        eventChannel.setStreamHandler(this)

        val filter = IntentFilter(ACTION_USB_PERMISSION)
        context.registerReceiver(permissionReceiver, filter)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "listDevices" -> handleListDevices(call, result)
            "requestDevice" -> handleRequestDevice(call, result)
            "openDevice" -> handleOpenDevice(call, result)
            "closeDevice" -> handleCloseDevice(call, result)
            "sendOutputReport" -> handleSendOutput(call, result)
            "sendFeatureReport" -> handleSendFeature(call, result)
            "getFeatureReport" -> handleGetFeature(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        context.unregisterReceiver(permissionReceiver)
        stopAll()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ActivityAware hooks (USB host does not require an activity, kept for completeness)
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {}
    override fun onDetachedFromActivityForConfigChanges() {}
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {}
    override fun onDetachedFromActivity() {}

    private fun handleListDevices(call: MethodCall, result: Result) {
        val filters = call.argument<List<Map<String, Any>>>("filters")
        val devices = usbManager.deviceList.values.filter { matchesFilters(it, filters) }
        result.success(devices.map { encodeDevice(it, false) })
    }

    private fun handleRequestDevice(call: MethodCall, result: Result) {
        val filters = call.argument<List<Map<String, Any>>>("filters")
        val device = usbManager.deviceList.values.firstOrNull { matchesFilters(it, filters) }
        if (device == null) {
            result.success(null)
            return
        }
        if (usbManager.hasPermission(device)) {
            result.success(encodeDevice(device, false))
            return
        }
        synchronized(permissionLock) {
            if (pendingPermission != null) {
                result.error("in_progress", "Another permission request is in progress", null)
                return
            }
            pendingPermission = PendingPermission(device, result)
        }
        val intent = PendingIntent.getBroadcast(
            context,
            0,
            Intent(ACTION_USB_PERMISSION),
            PendingIntent.FLAG_IMMUTABLE
        )
        usbManager.requestPermission(device, intent)
    }

    private fun handleOpenDevice(call: MethodCall, result: Result) {
        val deviceMap = call.argument<Map<String, Any>>("device")
        val deviceIdStr = deviceMap?.get("id") as? String
        if (deviceIdStr == null) {
            result.error("invalid_args", "device.id missing", null)
            return
        }
        val target = usbManager.deviceList.values.firstOrNull { encodeId(it) == deviceIdStr }
        if (target == null) {
            result.error("not_found", "device not found", null)
            return
        }
        if (!usbManager.hasPermission(target)) {
            result.error("permission_denied", "permission not granted", null)
            return
        }
        val iface = target.interfaces.find { it.interfaceClass == UsbConstants.USB_CLASS_HID }
        if (iface == null) {
            result.error("no_interface", "HID interface not found", null)
            return
        }
        val connection = usbManager.openDevice(target)
        if (connection == null || !connection.claimInterface(iface, true)) {
            result.error("open_failed", "Failed to open/claim interface", null)
            connection?.close()
            return
        }

        var inEp: UsbEndpoint? = null
        var outEp: UsbEndpoint? = null
        for (i in 0 until iface.endpointCount) {
            val ep = iface.getEndpoint(i)
            if (ep.type == UsbConstants.USB_ENDPOINT_XFER_INT) {
                if (ep.direction == UsbConstants.USB_DIR_IN) inEp = ep
                if (ep.direction == UsbConstants.USB_DIR_OUT) outEp = ep
            }
        }

        val handleId = nextHandleId++
        val handle = OpenHandle(handleId, target, connection, iface, inEp, outEp)
        startReader(handle)
        synchronized(handlesLock) { openHandles[handleId] = handle }
        result.success(mapOf("handle" to handleId))
    }

    private fun handleCloseDevice(call: MethodCall, result: Result) {
        val handleId = call.argument<Int>("handle")
        if (handleId == null) {
            result.error("invalid_args", "handle missing", null)
            return
        }
        val handle = synchronized(handlesLock) { openHandles.remove(handleId) }
        if (handle != null) {
            handle.running.set(false)
            handle.readerThread?.interrupt()
            handle.connection.releaseInterface(handle.iface)
            handle.connection.close()
        }
        result.success(null)
    }

    private fun handleSendOutput(call: MethodCall, result: Result) {
        val handle = getHandle(call, result) ?: return
        val reportId = call.argument<Int>("reportId") ?: 0
        val data = call.argument<ByteArray>("data") ?: ByteArray(0)
        val buffer = ByteArray(data.size + 1)
        buffer[0] = reportId.toByte()
        System.arraycopy(data, 0, buffer, 1, data.size)

        handle.outEndpoint?.let { outEp ->
            val written = handle.connection.bulkTransfer(outEp, buffer, buffer.size, 1000)
            if (written < 0) {
                result.error("write_failed", "bulkTransfer failed", null)
            } else {
                result.success(written)
            }
            return
        }

        val reqType = UsbConstants.USB_DIR_OUT or UsbConstants.USB_TYPE_CLASS or UsbConstants.USB_RECIP_INTERFACE
        val value = (3 shl 8) or (reportId and 0xFF)
        val sent = handle.connection.controlTransfer(reqType, 0x09, value, handle.iface.id, buffer, buffer.size, 1000)
        if (sent < 0) {
            result.error("write_failed", "controlTransfer failed", null)
        } else {
            result.success(sent)
        }
    }

    private fun handleSendFeature(call: MethodCall, result: Result) {
        val handle = getHandle(call, result) ?: return
        val reportId = call.argument<Int>("reportId") ?: 0
        val data = call.argument<ByteArray>("data") ?: ByteArray(0)
        val buffer = ByteArray(data.size + 1)
        buffer[0] = reportId.toByte()
        System.arraycopy(data, 0, buffer, 1, data.size)
        val reqType = UsbConstants.USB_DIR_OUT or UsbConstants.USB_TYPE_CLASS or UsbConstants.USB_RECIP_INTERFACE
        val value = (3 shl 8) or (reportId and 0xFF)
        val sent = handle.connection.controlTransfer(reqType, 0x09, value, handle.iface.id, buffer, buffer.size, 1000)
        if (sent < 0) {
            result.error("feature_failed", "controlTransfer failed", null)
        } else {
            result.success(null)
        }
    }

    private fun handleGetFeature(call: MethodCall, result: Result) {
        val handle = getHandle(call, result) ?: return
        val reportId = call.argument<Int>("reportId") ?: 0
        val length = call.argument<Int>("length") ?: 0
        val buffer = ByteArray(length + 1)
        buffer[0] = reportId.toByte()
        val reqType = UsbConstants.USB_DIR_IN or UsbConstants.USB_TYPE_CLASS or UsbConstants.USB_RECIP_INTERFACE
        val value = (3 shl 8) or (reportId and 0xFF)
        val read = handle.connection.controlTransfer(reqType, 0x01, value, handle.iface.id, buffer, buffer.size, 1000)
        if (read < 0) {
            result.success(null)
        } else {
            result.success(buffer.copyOf(read))
        }
    }

    private fun startReader(handle: OpenHandle) {
        val inEp = handle.inEndpoint ?: return
        handle.readerThread = thread(start = true, name = "usb-hid-reader-${handle.handleId}") {
            val buffer = ByteArray(inEp.maxPacketSize)
            while (handle.running.get()) {
                val read = handle.connection.bulkTransfer(inEp, buffer, buffer.size, 500)
                if (read != null && read > 0) {
                    val payload = buffer.copyOf(read)
                    val reportId = payload.firstOrNull()?.toInt() ?: 0
                    emitInputReport(handle.device, reportId, payload)
                }
            }
        }
    }

    private fun emitInputReport(device: UsbDevice, reportId: Int, data: ByteArray) {
        val sink = eventSink ?: return
        val map = mapOf(
            "deviceId" to encodeId(device),
            "reportId" to reportId,
            "data" to data,
        )
        sink.success(map)
    }

    private fun stopAll() {
        val handles: List<OpenHandle>
        synchronized(handlesLock) {
            handles = openHandles.values.toList()
            openHandles.clear()
        }
        for (handle in handles) {
            handle.running.set(false)
            handle.readerThread?.interrupt()
            handle.connection.releaseInterface(handle.iface)
            handle.connection.close()
        }
    }

    private fun encodeDevice(device: UsbDevice, opened: Boolean): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>(
            "id" to encodeId(device),
            "vendorId" to device.vendorId,
            "productId" to device.productId,
            "opened" to opened,
            "usagePage" to null,
            "usage" to null
        )
        if (device.manufacturerName != null) map["manufacturerName"] = device.manufacturerName
        if (device.productName != null) map["productName"] = device.productName
        if (device.serialNumber != null) map["serialNumber"] = device.serialNumber
        return map
    }

    private fun encodeId(device: UsbDevice): String = "android-${device.deviceId}"

    private fun matchesFilters(device: UsbDevice, filters: List<Map<String, Any>>?): Boolean {
        if (filters == null || filters.isEmpty()) return true
        return filters.any { filter ->
            val vid = filter["vendorId"] as? Int
            val pid = filter["productId"] as? Int
            val usagePage = filter["usagePage"] as? Int
            val usage = filter["usage"] as? Int

            val vidOk = vid == null || vid == device.vendorId
            val pidOk = pid == null || pid == device.productId
            val usageOk = usage == null
            val usagePageOk = usagePage == null
            vidOk && pidOk && usageOk && usagePageOk
        }
    }

    private fun getHandle(call: MethodCall, result: Result): OpenHandle? {
        val handleId = call.argument<Int>("handle")
        if (handleId == null) {
            result.error("invalid_args", "handle missing", null)
            return null
        }
        val handle = synchronized(handlesLock) { openHandles[handleId] }
        if (handle == null) {
            result.error("not_open", "handle not found", null)
            return null
        }
        return handle
    }
}
