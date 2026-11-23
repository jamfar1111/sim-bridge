package com.simbridge.sim_bridge

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * `com.simbridge/telecom` — Android default-dialer bridge.
 *
 * Methods (see `lib/src/link/channels.dart` `TelecomBridge`):
 * `isDefaultDialer`, `requestDefaultDialer`, `liveCalls`, `answerCall`,
 * `rejectCall`, `endCall`, `holdCall`, `muteCall`, `dtmf`, `dial`.
 * Extra method (not in the Dart contract yet — see NATIVE_CHANNELS.md):
 * `setBlockedNumbers` — writes the screening-service block list.
 *
 * Events (`com.simbridge/telecom/events`): one `CallInfo` map per
 * call-state change.
 */
class TelecomPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {

    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var appContext: android.content.Context? = null
    private var pendingDialerResult: MethodChannel.Result? = null

    private val listener: (Map<String, Any?>) -> Unit = { info ->
        Handler(Looper.getMainLooper()).post { sink?.success(info) }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "com.simbridge/telecom").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "com.simbridge/telecom/events").also { it.setStreamHandler(this) }
        CallRegistry.addListener(listener)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        CallRegistry.removeListener(listener)
        methods?.setMethodCallHandler(null)
        methods = null
        events?.setStreamHandler(null)
        events = null
        sink = null
        appContext = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ---- ActivityAware (needed for the default-dialer role request) ----

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() { activity = null }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_DIALER_ROLE) return false
        val ctx = appContext
        val ok = ctx != null && CallRegistry.isDefaultDialer(ctx)
        pendingDialerResult?.success(ok)
        pendingDialerResult = null
        return true
    }

    // ---- MethodChannel ----

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) { result.error("detached", "telecom plugin detached", null); return }
        when (call.method) {
            "isDefaultDialer" -> result.success(CallRegistry.isDefaultDialer(ctx))
            "requestDefaultDialer" -> {
                val intent = CallRegistry.defaultDialerIntent(ctx)
                val act = activity
                if (intent == null || act == null) {
                    result.success(false)
                    return
                }
                if (pendingDialerResult != null) {
                    result.error("busy", "a dialer request is already pending", null)
                    return
                }
                pendingDialerResult = result
                act.startActivityForResult(intent, REQUEST_DIALER_ROLE)
            }
            "liveCalls" -> result.success(CallRegistry.list())
            "answerCall" -> result.success(CallRegistry.answer(call.argument<String>("cid") ?: ""))
            "rejectCall" -> result.success(CallRegistry.reject(call.argument<String>("cid") ?: ""))
            "endCall" -> result.success(CallRegistry.end(call.argument<String>("cid") ?: ""))
            "holdCall" -> result.success(
                CallRegistry.hold(call.argument<String>("cid") ?: "", call.argument<Boolean>("on") ?: false))
            "muteCall" -> result.success(CallRegistry.mute(call.argument<Boolean>("on") ?: false))
            "dtmf" -> {
                val digit = call.argument<String>("d")?.firstOrNull() ?: ' '
                result.success(CallRegistry.dtmf(call.argument<String>("cid") ?: "", digit))
            }
            "dial" -> {
                val num = call.argument<String>("num") ?: ""
                val sub = (call.argument<Number>("sub"))?.toInt()
                val err = CallRegistry.dial(ctx, num, sub)
                result.success(mapOf("ok" to (err == null), "err" to err))
            }
            "setBlockedNumbers" -> {
                @Suppress("UNCHECKED_CAST")
                val numbers = (call.argument<List<*>>("numbers") ?: emptyList<Any>())
                    .mapNotNull { it as? String }.toSet()
                ctx.getSharedPreferences("sim_bridge", android.content.Context.MODE_PRIVATE)
                    .edit().putStringSet("blocked_numbers", numbers).apply()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val REQUEST_DIALER_ROLE = 0x5B1D
    }
}
