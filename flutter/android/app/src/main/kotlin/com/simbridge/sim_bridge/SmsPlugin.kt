package com.simbridge.sim_bridge

import android.app.Activity
import android.app.role.RoleManager
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * `com.simbridge/sms` — Android SMS provider bridge.
 *
 * Contract methods (see `lib/src/link/channels.dart` `SmsBridge`):
 * `sendSms`, `markRead`, `deleteMessages`, `deleteCalls`,
 * `isDefaultSmsApp`, `requestDefaultSmsApp`.
 *
 * Extra methods for `HubData` (see NATIVE_CHANNELS.md — the UI agent
 * calls these from its `HubData` implementation): `smsSince`,
 * `callsSince`, `contactsAll`, `contactsVersion`, `smsAllIds`,
 * `callAllIds`, `unreadSmsIds`, `statusJson`, `setContactStarred`,
 * `addContact`, `updateContact`, `listsJson`, `setLists`.
 *
 * Events (`com.simbridge/sms/events`): `sms.new` (with `item`),
 * `sms.result` (with `localId`, `state`, `ok`, `err`),
 * `sms.readChanged` (with `ids` = unread incoming ids).
 *
 * Writes (mark read / delete) need the WRITE_SMS app-op when the app
 * is not the default SMS app; without it they return -1 / null, the
 * same as Tether (grant it through adb: see NATIVE_CHANNELS.md).
 */
class SmsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {

    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var appContext: android.content.Context? = null
    private var pendingSmsRoleResult: MethodChannel.Result? = null

    private lateinit var sms: SmsRepo
    private lateinit var contacts: ContactsRepo
    private lateinit var calls: CallLogRepo
    private lateinit var sims: SimRepo
    private lateinit var lists: ListsRepo

    private val main = Handler(Looper.getMainLooper())
    private fun post(block: () -> Unit) = main.post(block)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        appContext = ctx
        sms = SmsRepo(ctx)
        contacts = ContactsRepo(ctx)
        sims = SimRepo(ctx)
        calls = CallLogRepo(ctx, sims)
        lists = ListsRepo(ctx)
        methods = MethodChannel(binding.binaryMessenger, "com.simbridge/sms").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "com.simbridge/sms/events").also { it.setStreamHandler(this) }
        SmsEvents.onSmsReceived = { pollSms() }
        SmsEvents.onSmsResult = { localId, state, ok, err ->
            post { sink?.success(mapOf("t" to "sms.result", "localId" to localId, "state" to state, "ok" to ok, "err" to err)) }
        }
        SmsEvents.onReadChanged = { emitReadChanged() }
        sms.observe(
            onNew = { row -> post { sink?.success(mapOf("t" to "sms.new", "item" to row.toJson())) } },
            onReadChanged = { emitReadChanged() },
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        sms.stop()
        SmsEvents.onSmsReceived = null
        SmsEvents.onSmsResult = null
        SmsEvents.onReadChanged = null
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

    private fun pollSms() {
        // The broadcast fired before the provider stored the row; the observer usually covers it,
        // but poll anyway so nothing is missed.
        sms.poll { row -> post { sink?.success(mapOf("t" to "sms.new", "item" to row.toJson())) } }
    }

    private fun emitReadChanged() {
        val ids = sms.unreadIds() ?: return // null = provider unreadable: send nothing (an empty list would mark everything read)
        post { sink?.success(mapOf("t" to "sms.readChanged", "ids" to ids)) }
    }

    // ---- ActivityAware (default-SMS role request) ----

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
        if (requestCode != REQUEST_SMS_ROLE) return false
        val ctx = appContext
        val ok = ctx != null && Telephony.Sms.getDefaultSmsPackage(ctx) == ctx.packageName
        pendingSmsRoleResult?.success(ok)
        pendingSmsRoleResult = null
        return true
    }

    // ---- MethodChannel ----

    @Suppress("UNCHECKED_CAST")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null) { result.error("detached", "sms plugin detached", null); return }
        fun numArg(name: String): Long? = (call.argument<Number>(name))?.toLong()
        when (call.method) {
            "sendSms" -> {
                val to = call.argument<String>("to") ?: ""
                val body = call.argument<String>("body") ?: ""
                val sub = (call.argument<Number>("sub"))?.toInt()
                val localId = (call.argument<Number>("localId"))?.toInt() ?: 0
                val err = sms.send(to, body, sub, localId)
                result.success(mapOf("ok" to (err == null), "err" to err))
            }
            "markRead" -> result.success(sms.markRead(numArg("thread") ?: 0L, numArg("upTo") ?: 0L))
            "deleteMessages" -> {
                val ids = (call.argument<List<*>>("ids") ?: emptyList<Any>()).mapNotNull { (it as? Number)?.toLong() }
                val thread = numArg("thread")
                val deleted = sms.delete(ids, thread)
                result.success(deleted)
            }
            "deleteCalls" -> {
                val ids = (call.argument<List<*>>("ids") as? List<*>)?.mapNotNull { (it as? Number)?.toLong() }
                result.success(calls.delete(ids))
            }
            "isDefaultSmsApp" -> result.success(Telephony.Sms.getDefaultSmsPackage(ctx) == ctx.packageName)
            "requestDefaultSmsApp" -> {
                val rm = ctx.getSystemService(RoleManager::class.java)
                val act = activity
                if (rm == null || act == null || !rm.isRoleAvailable(RoleManager.ROLE_SMS)) {
                    result.success(false)
                    return
                }
                if (pendingSmsRoleResult != null) {
                    result.error("busy", "an SMS role request is already pending", null)
                    return
                }
                pendingSmsRoleResult = result
                act.startActivityForResult(rm.createRequestRoleIntent(RoleManager.ROLE_SMS), REQUEST_SMS_ROLE)
            }
            // ---- HubData extras ----
            "smsSince" -> result.success(sms.since(numArg("since") ?: 0L).map { it.toJson() })
            "callsSince" -> result.success(calls.since(numArg("since") ?: 0L))
            "contactsAll" -> result.success(contacts.all())
            "contactsVersion" -> result.success(contacts.version())
            "smsAllIds" -> result.success(sms.allIds())
            "callAllIds" -> result.success(calls.allIds())
            "unreadSmsIds" -> result.success(sms.unreadIds()) // null = provider unreadable: the Dart Hub sends no sms.unread then (an empty list would mark everything read)
            "statusJson" -> result.success(sims.status(CallAudioPlugin.helperState))
            "setContactStarred" -> result.success(contacts.setStarred(numArg("id") ?: 0L, call.argument<Boolean>("on") ?: false))
            "addContact" -> {
                val name = call.argument<String>("name") ?: ""
                val phones = (call.argument<List<*>>("phones") ?: emptyList<Any>())
                    .mapNotNull { it as? Map<String, Any?> }
                val emails = (call.argument<List<*>>("emails") ?: emptyList<Any>()).mapNotNull { it as? String }
                result.success(contacts.add(name, phones, emails))
            }
            "updateContact" -> {
                val id = numArg("id") ?: 0L
                val name = call.argument<String>("name") ?: ""
                val phones = (call.argument<List<*>>("phones") ?: emptyList<Any>())
                    .mapNotNull { it as? Map<String, Any?> }
                val emails = (call.argument<List<*>>("emails") ?: emptyList<Any>()).mapNotNull { it as? String }
                val err = contacts.update(id, name, phones, emails)
                result.success(mapOf("ok" to (err == null), "err" to err))
            }
            "listsJson" -> result.success(lists.json())
            "setLists" -> {
                val what = call.argument<String>("what") ?: ""
                val on = call.argument<Boolean>("on") ?: false
                val out = when (what) {
                    "block" -> {
                        val num = call.argument<String>("num") ?: ""
                        val where = lists.setBlocked(num, on)
                        lists.json().toMutableMap().also { it["where"] = where }
                    }
                    "mute" -> {
                        val thread = numArg("thread") ?: -1L
                        if (thread >= 0) lists.setMuted(thread, on)
                        lists.json().toMutableMap().also { it["where"] = "tether" }
                    }
                    else -> lists.json().toMutableMap().also { it["where"] = "error: unknown list '$what'" }
                }
                result.success(out)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val REQUEST_SMS_ROLE = 0x5B15
    }
}
