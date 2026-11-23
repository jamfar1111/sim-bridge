package com.simbridge.sim_bridge

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * `com.simbridge/ble` — Android peripheral side.
 *
 * Owns the [BlePeripheral] and forwards its callbacks as
 * `com.simbridge/ble/events` events (see `lib/src/link/channels.dart`
 * `BleEvent.parse`): raw bytes as a byte array, everything else as a
 * map `{'t': kind, 'address': ..., 'bytes': ..., 'mtu': ...}`.
 *
 * The `psm` argument of `startAdvertising` is informational: Android
 * assigns the L2CAP PSM when the listener opens, and the value is
 * published in the PSM characteristic for the central to read.
 *
 * ActivityAware only for `requestEnableBluetooth` (the system
 * "turn on Bluetooth" dialog needs an Activity to start from).
 */
class BlePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var peripheral: BlePeripheral? = null
    private var sink: EventChannel.EventSink? = null
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var pendingBtResult: MethodChannel.Result? = null

    /** Classic / LE ACL connects and disconnects: the peripheral ends a GATT pipe whose bearer moved (see BlePeripheral.onAcl). */
    private val aclReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val d: android.bluetooth.BluetoothDevice? =
                i.getParcelableExtra(android.bluetooth.BluetoothDevice.EXTRA_DEVICE, android.bluetooth.BluetoothDevice::class.java)
            val t = i.getIntExtra(android.bluetooth.BluetoothDevice.EXTRA_TRANSPORT, -1)
            if (t != 1 && t != 2) return
            when (i.action) {
                android.bluetooth.BluetoothDevice.ACTION_ACL_CONNECTED ->
                    peripheral?.onAcl(d?.address, le = t == 2, up = true)
                android.bluetooth.BluetoothDevice.ACTION_ACL_DISCONNECTED ->
                    peripheral?.onAcl(d?.address, le = t == 2, up = false)
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        peripheral = BlePeripheral(binding.applicationContext)
        methods = MethodChannel(binding.binaryMessenger, "com.simbridge/ble").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "com.simbridge/ble/events").also { it.setStreamHandler(this) }
        val p = peripheral!!
        p.onBytes = { address, bytes -> post { sink?.success(bytes) } }
        p.onClosed = { address -> post { sink?.success(mapOf("t" to "closed", "address" to address)) } }
        p.onPeerRestart = { address, first -> post { sink?.success(mapOf("t" to "peerRestart", "address" to address, "bytes" to first)) } }
        p.onMtuChanged = { address, mtu -> post { sink?.success(mapOf("t" to "mtuChanged", "address" to address, "mtu" to mtu)) } }
        p.onConnected = { address -> post { sink?.success(mapOf("t" to "connected", "address" to address)) } }
        p.onDisconnected = { address -> post { sink?.success(mapOf("t" to "disconnected", "address" to address)) } }
        val filter = IntentFilter().apply {
            addAction(android.bluetooth.BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(android.bluetooth.BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            binding.applicationContext.registerReceiver(aclReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            binding.applicationContext.registerReceiver(aclReceiver, filter)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        runCatching { binding.applicationContext.unregisterReceiver(aclReceiver) }
        peripheral?.stop()
        peripheral = null
        appContext = null
        methods?.setMethodCallHandler(null)
        methods = null
        events?.setStreamHandler(null)
        events = null
        sink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ---- ActivityAware (needed for the "turn on Bluetooth" dialog) ----

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        // Never leak a pending enable-Bluetooth result.
        pendingBtResult?.success(false)
        pendingBtResult = null
        activity = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_ENABLE_BT) return false
        pendingBtResult?.success(isBluetoothOn())
        pendingBtResult = null
        return true
    }

    /** Bluetooth on, or false when there is no adapter / the
     * BLUETOOTH_CONNECT permission is missing (API 31+ throws
     * SecurityException for `isEnabled` without it). */
    private fun isBluetoothOn(): Boolean = try {
        appContext?.getSystemService(BluetoothManager::class.java)
            ?.adapter?.isEnabled == true
    } catch (_: SecurityException) {
        false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Bluetooth state / enable do not need the peripheral.
        when (call.method) {
            "isBluetoothOn" -> {
                result.success(isBluetoothOn())
                return
            }
            "requestEnableBluetooth" -> {
                if (isBluetoothOn()) {
                    result.success(true)
                    return
                }
                val act = activity
                if (act == null) {
                    result.success(false)
                    return
                }
                if (pendingBtResult != null) {
                    result.error("busy", "a Bluetooth enable request is already pending", null)
                    return
                }
                pendingBtResult = result
                act.startActivityForResult(
                    Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                    REQUEST_ENABLE_BT,
                )
                return
            }
        }
        val p = peripheral
        if (p == null) { result.error("detached", "BLE plugin detached", null); return }
        when (call.method) {
            "startAdvertising" -> {
                val uuid = call.argument<String>("serviceUuid")
                if (uuid != null && !uuid.equals(BlePeripheral.SERVICE.toString(), ignoreCase = true)) {
                    Log.w(BlePeripheral.TAG, "startAdvertising: unexpected service UUID $uuid (using ${BlePeripheral.SERVICE})")
                }
                p.start()
                result.success(p.running)
            }
            "stopAdvertising" -> {
                p.stop()
                result.success(null)
            }
            "connect" -> {
                // Peripheral side: there is nothing to connect to; the central connects to us.
                // Kept for API symmetry with the iOS central.
                result.error("unsupported", "Android is the peripheral; the peer connects to us", null)
            }
            "disconnect" -> {
                p.stop()
                result.success(null)
            }
            "write" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) { result.error("bad_args", "write needs 'bytes'", null); return }
                val address = call.argument<String>("address")
                result.success(p.write(address ?: "", bytes))
            }
            "wake" -> {
                val address = call.argument<String>("address") ?: ""
                p.wake(address)
                result.success(null)
            }
            "tune" -> {
                val address = call.argument<String>("address") ?: ""
                val high = call.argument<Boolean>("high") ?: false
                p.tune(address, high)
                result.success(null)
            }
            "isConnected" -> {
                val address = call.argument<String>("address")
                result.success(p.isConnected(address))
            }
            // ---- LE link management (extra methods, see NATIVE_CHANNELS.md) ----
            // The Dart side drives these from the link state: setLinked when a session comes up / ends,
            // ensureAdvertising on a timer (the stack can stop advertising by itself), holdLe/pulseLe to
            // keep or wake the iPhone's LE link, closeLeConnection to drop a stale one.
            "setLinked" -> {
                p.setLinked(call.argument<Boolean>("on") ?: false)
                result.success(null)
            }
            "ensureAdvertising" -> {
                p.ensureAdvertising()
                result.success(p.advertising)
            }
            "holdLe" -> {
                p.holdLe(call.argument<String>("address") ?: "")
                result.success(null)
            }
            "releaseLe" -> {
                p.releaseLe(call.argument<String>("address") ?: "")
                result.success(null)
            }
            "pulseLe" -> {
                p.pulseLe(call.argument<String>("address") ?: "")
                result.success(null)
            }
            "closeLeConnection" -> {
                p.closeLeConnection(call.argument<String>("address") ?: "")
                result.success(null)
            }
            "linkState" -> result.success(mapOf(
                "psm" to p.psm,
                "running" to p.running,
                "advertising" to p.advertising,
                "securityCheck" to p.securityCheck,
                "linkParams" to p.linkParams.toMap(),
            ))
            else -> result.notImplemented()
        }
    }

    /** EventChannel sinks must be called on the platform thread; peripheral callbacks arrive on BLE threads. */
    private fun post(block: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)
    }

    companion object {
        private const val REQUEST_ENABLE_BT = 0x5B17
    }
}
