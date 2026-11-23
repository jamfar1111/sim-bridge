package com.simbridge.sim_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * `com.simbridge/audio` — call-audio bridge.
 *
 * Owns the [HelperBridge] (the shell helper, uid 2000, started through
 * the phone's own Wireless debugging) and the Opus codecs. The helper
 * captures the call downlink and injects the uplink; Dart only steers
 * it and moves PCM frames.
 *
 * Contract methods (see `lib/src/link/channels.dart`
 * `CallAudioBridge`): `ensureHelperRunning`, `probe`,
 * `startCapture`, `stopCapture`, `injectUplink`, `selftest`.
 *
 * Extra methods (see NATIVE_CHANNELS.md): `opusEncode`,
 * `opusDecode` (the Dart side has no Opus implementation),
 * `netControl` (`HubData.netControl`), `helperState`,
 * `pairAdb` / `enableWirelessDebugging` / `bootstrapAdb` /
 * `adbPaired` (one-time Wireless-debugging setup).
 *
 * Events (`com.simbridge/audio/events`): downlink PCM frames
 * (16-bit little-endian mono, 20 ms each) as byte arrays.
 *
 * The helper's state document is published as [helperState] so
 * `SmsPlugin.statusJson` can include it.
 */
class CallAudioPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var appContext: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private val codecExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "opus-codec").apply { isDaemon = true } }
    private val opusEncode = OpusCodec()
    private val opusDecode = OpusCodec()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        appContext = ctx
        // Notification channels (Tether's Application created these; the Flutter app has none).
        // "setup" is used by the Wireless-debugging pairing notification (Adb.kt); "calls" by the audio service.
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(Adb.CH_SETUP, "Setup", NotificationManager.IMPORTANCE_HIGH))
            nm.createNotificationChannel(NotificationChannel(AudioForegroundService.CH_CALLS, "Calls", NotificationManager.IMPORTANCE_LOW))
        }
        Companion.bridge = Companion.bridge ?: HelperBridge(ctx).also { b ->
            b.onDown = { pcm -> onDownlink(pcm) }
            b.onChange = { refreshHelperState() }
            b.listen()
        }
        methods = MethodChannel(binding.binaryMessenger, "com.simbridge/audio").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "com.simbridge/audio/events").also { it.setStreamHandler(this) }
        refreshHelperState()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        methods = null
        events?.setStreamHandler(null)
        events = null
        sink = null
        appContext = null
        codecExecutor.shutdown()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun onDownlink(pcm: ShortArray) {
        val bytes = ByteArray(pcm.size * 2)
        for (i in pcm.indices) {
            bytes[2 * i] = pcm[i].toInt().toByte()
            bytes[2 * i + 1] = (pcm[i].toInt() shr 8).toByte()
        }
        main.post { sink?.success(bytes) }
    }

    private fun refreshHelperState() {
        helperState = bridge?.state()?.let { jsonToMap(it) } ?: emptyMap()
    }

    private fun ensureBridge(): HelperBridge? = bridge

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) { result.error("detached", "audio plugin detached", null); return }
        val b = ensureBridge()
        when (call.method) {
            "ensureHelperRunning" -> {
                // Blocking I/O (up to 25 s) must not run on the platform thread.
                Thread({
                    val err = b?.ensureRunning()
                    refreshHelperState()
                    main.post {
                        if (err == null) result.success(helperState) else result.success(null)
                    }
                }, "helper-ensure").start()
            }
            "probe" -> {
                Thread({
                    val doc = b?.request("probe")
                    main.post { result.success(doc?.let { jsonToMap(it) }) }
                }, "helper-probe").start()
            }
            "startCapture" -> {
                val rate = (call.argument<Number>("rate"))?.toInt() ?: 16000
                val method = call.argument<String>("method") ?: "auto"
                val inject = call.argument<String>("inject") ?: "auto"
                Thread({
                    val err = b?.ensureRunning()
                    if (err == null) {
                        b?.start(rate, method, inject)
                        ctx.startForegroundService(Intent(ctx, AudioForegroundService::class.java))
                    } else {
                        Log.w(TAG, "startCapture: helper not running ($err)")
                    }
                    refreshHelperState()
                    main.post { result.success(null) }
                }, "helper-start").start()
            }
            "stopCapture" -> {
                b?.stop()
                ctx.stopService(Intent(ctx, AudioForegroundService::class.java))
                refreshHelperState()
                result.success(null)
            }
            "injectUplink" -> {
                val pcm = call.argument<ByteArray>("pcm") ?: byteArrayOf()
                val shorts = ShortArray(pcm.size / 2) { i ->
                    (pcm[2 * i].toInt() and 0xff or (pcm[2 * i + 1].toInt() shl 8)).toShort()
                }
                // Dropped silently when the helper is gone: the call is over or the audio path is down.
                b?.up(shorts)
                result.success(null)
            }
            "selftest" -> {
                val timeout = (call.argument<Number>("timeout"))?.toLong() ?: 40L
                Thread({
                    val doc = b?.request("selftest", timeout)
                    main.post { result.success(doc?.let { jsonToMap(it) } ?: mapOf("ok" to false)) }
                }, "helper-selftest").start()
            }
            "opusEncode" -> {
                val pcm = call.argument<ByteArray>("pcm") ?: byteArrayOf()
                codecExecutor.execute {
                    try {
                        val shorts = ShortArray(pcm.size / 2) { i ->
                            (pcm[2 * i].toInt() and 0xff or (pcm[2 * i + 1].toInt() shl 8)).toShort()
                        }
                        val frames = opusEncode.encode(shorts)
                        main.post { result.success(frames) }
                    } catch (t: Throwable) {
                        main.post { result.error("opus", t.message ?: t.javaClass.simpleName, null) }
                    }
                }
            }
            "opusDecode" -> {
                val frame = call.argument<ByteArray>("frame") ?: byteArrayOf()
                codecExecutor.execute {
                    try {
                        val pcm = opusDecode.decode(frame)
                        val bytes = if (pcm == null) byteArrayOf() else ByteArray(pcm.size * 2).also { out ->
                            for (i in pcm.indices) {
                                out[2 * i] = pcm[i].toInt().toByte()
                                out[2 * i + 1] = (pcm[i].toInt() shr 8).toByte()
                            }
                        }
                        main.post { result.success(bytes) }
                    } catch (t: Throwable) {
                        main.post { result.error("opus", t.message ?: t.javaClass.simpleName, null) }
                    }
                }
            }
            "netControl" -> {
                val what = call.argument<String>("what")
                val on = call.argument<Boolean>("on") ?: false
                val sub = (call.argument<Number>("sub"))?.toInt()
                val slot = (call.argument<Number>("slot"))?.toInt()
                val mode = call.argument<String>("mode")
                Thread({
                    val extra = JSONObject().apply {
                        slot?.let { put("slot", it) }
                        mode?.let { put("mode", it) }
                    }
                    val doc = b?.net(what, on, sub, extra)
                    main.post { result.success(doc?.let { jsonToMap(it) }) }
                }, "helper-net").start()
            }
            "helperState" -> {
                refreshHelperState()
                result.success(helperState)
            }
            "adbPaired" -> result.success(
                ctx.getSharedPreferences("sim_bridge", Context.MODE_PRIVATE).getBoolean("adb_paired", false))
            "enableWirelessDebugging" -> result.success(Adb.enableWirelessDebugging(ctx))
            "pairAdb" -> {
                // Shows the pairing notification; the user types the 6-digit code from Settings into it.
                Adb.showPairingNotification(ctx)
                result.success(null)
            }
            "bootstrapAdb" -> {
                Thread({
                    val out = runCatching { Adb.bootstrap(ctx) }.getOrElse { t -> "bootstrap failed: ${t.message}" }
                    main.post { result.success(out) }
                }, "adb-bootstrap").start()
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val TAG = "SimBridge"

        /** The shared bridge: also reachable from [AdbPairingReceiver] after a successful pairing. */
        @Volatile var bridge: HelperBridge? = null
            private set

        /** Last known helper state document, for `SmsPlugin.statusJson`. */
        @Volatile var helperState: Map<String, Any?> = emptyMap()
            private set

        /** Starts the helper (from the pairing receiver, where there is no plugin instance). */
        fun kickHelper(ctx: Context) {
            val b = bridge ?: HelperBridge(ctx.applicationContext).also { bridge = it }
            Thread({ b.ensureRunning() }, "helper-kick").start()
        }
    }
}

/** JSONObject → Map/List tree for MethodChannel results. */
fun jsonToMap(o: JSONObject): Map<String, Any?> {
    val m = mutableMapOf<String, Any?>()
    val keys = o.keys()
    while (keys.hasNext()) {
        val k = keys.next()
        m[k] = jsonValue(o.opt(k))
    }
    return m
}

private fun jsonValue(v: Any?): Any? = when (v) {
    is JSONObject -> jsonToMap(v)
    is org.json.JSONArray -> List(v.length()) { i -> jsonValue(v.opt(i)) }
    JSONObject.NULL -> null
    else -> v
}

/**
 * Minimal foreground service: keeps the app process alive while call
 * audio is bridged. The audio itself flows through the shell helper;
 * this service only holds the foreground notification.
 */
class AudioForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(CH_CALLS, "Calls", NotificationManager.IMPORTANCE_LOW))
        }
        val n = Notification.Builder(this, CH_CALLS)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Sim Bridge")
            .setContentText("Call audio active")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_AUDIO, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
        } else {
            startForeground(NOTIF_AUDIO, n)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        const val CH_CALLS = "calls"
        const val NOTIF_AUDIO = 21
    }
}
