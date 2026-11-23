package com.simbridge.sim_bridge

import android.annotation.SuppressLint
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.util.Log
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Which call a client's end / reject means: its own id; else, for an id this process never knew (the app
 * restarted mid-call), the only call there is; never another call when the id belongs to a call that ended here.
 */
fun <C> chooseCall(cid: String, calls: Map<String, C>, ended: Set<String>): C? =
    calls[cid] ?: if (cid in ended) null else calls.values.singleOrNull()

/** Tracks live calls (from our InCallService) and executes call actions coming from Dart / the iPhone. */
object CallRegistry {
    const val TAG = "SimBridge"
    private val calls = ConcurrentHashMap<String, Call>()
    private val ids = ConcurrentHashMap<Call, String>()
    private val listeners = CopyOnWriteArrayList<(Map<String, Any?>) -> Unit>()
    @Volatile var service: SimBridgeInCallService? = null
    private val main = Handler(Looper.getMainLooper())

    fun addListener(l: (Map<String, Any?>) -> Unit) { listeners.add(l) }
    fun removeListener(l: (Map<String, Any?>) -> Unit) { listeners.remove(l) }

    fun cidOf(c: Call): String = ids.getOrPut(c) { UUID.randomUUID().toString().substring(0, 8).also { calls[it] = c } }

    fun list(): List<Map<String, Any?>> = calls.values.map(::info)

    fun active(): List<Call> = calls.values.toList()

    fun hasActiveCall() = calls.values.any { it.details.state == Call.STATE_ACTIVE }

    /**
     * Audio is bridged while a call is active or on hold, and also while an outgoing call is dialing,
     * so the iPhone hears the network's ringback.
     */
    fun wantsAudio() = calls.values.any {
        val d = it.details
        when (d.state) {
            Call.STATE_ACTIVE, Call.STATE_HOLDING -> true
            Call.STATE_DIALING, Call.STATE_CONNECTING, Call.STATE_PULLING_CALL -> d.callDirection == Call.Details.DIRECTION_OUTGOING
            else -> false
        }
    }

    internal fun added(c: Call) {
        cidOf(c)
        c.registerCallback(callback)
        publish(c)
    }

    internal fun removed(c: Call) {
        c.unregisterCallback(callback)
        // Calls never registered (blocked callers, other apps' VoIP calls) end without telling anyone.
        val cid = ids.remove(c) ?: return
        calls.remove(cid)
        endedIds.add(cid)
        listeners.forEach { it(info(c, cid).toMutableMap().also { m -> m["state"] = "ended" }) }
    }

    /** Ids of calls that ended in this process: a late end / reject for one of them must not hit another call. */
    private val endedIds = java.util.Collections.newSetFromMap(ConcurrentHashMap<String, Boolean>())

    private val callback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) = publish(call)
        override fun onDetailsChanged(call: Call, details: Call.Details) = publish(call)
    }

    private fun publish(c: Call) {
        val i = info(c)
        listeners.forEach { it(i) }
    }

    fun stateName(s: Int) = when (s) {
        Call.STATE_RINGING -> "ringing"
        Call.STATE_DIALING, Call.STATE_PULLING_CALL -> "dialing"
        Call.STATE_ACTIVE -> "active"
        Call.STATE_HOLDING -> "holding"
        Call.STATE_DISCONNECTED, Call.STATE_DISCONNECTING -> "ended"
        else -> "connecting"
    }

    /**
     * The JSON shape of Dart's `CallInfo` (`lib/src/protocol/messages.dart`):
     * required `cid`, `num`, `state`, `dir`, `hold`; optional `name`, `sub`, `since`, `cause`,
     * `elsewhere`, `where`. Only non-null optionals are included.
     */
    fun info(c: Call, cid: String = cidOf(c)): Map<String, Any?> {
        val d = c.details
        val num = d.handle?.schemeSpecificPart ?: ""
        // No contacts query here: this runs on the ring path. The iPhone resolves names from its synced contacts.
        val name = d.contactDisplayName?.takeIf { it.isNotBlank() } ?: d.callerDisplayName?.takeIf { it.isNotBlank() }
        val dir = if (d.callDirection == Call.Details.DIRECTION_OUTGOING) "out" else "in"
        val m = mutableMapOf<String, Any?>(
            "cid" to cid,
            "num" to num,
            "state" to stateName(d.state),
            "dir" to dir,
            "hold" to d.can(Call.Details.CAPABILITY_HOLD),
        )
        name?.let { m["name"] = it }
        subFor(d.accountHandle)?.let { m["sub"] = it }
        d.connectTimeMillis.takeIf { it > 0 }?.let { m["since"] = it }
        d.disconnectCause?.reason?.takeIf { it.isNotBlank() }?.let { m["cause"] = it }
        return m
    }

    /** Subscription id for a phone account handle. SIM accounts carry the sub id as the handle id. */
    fun subFor(handle: android.telecom.PhoneAccountHandle?): Int? =
        handle?.id?.toIntOrNull()

    fun answer(cid: String) = calls[cid]?.answer(VideoProfile.STATE_AUDIO_ONLY) != null

    /** The call for an id from a client; if the id is unknown (e.g. the app restarted) but only one call exists, that one. */
    private fun callFor(cid: String): Call? = chooseCall(cid, calls, endedIds)?.also { if (calls[cid] == null) Log.w(TAG, "call $cid unknown, using the only call") }

    /** Reject a ringing call; a call that is no longer ringing is ended instead (the client's view was late). */
    fun reject(cid: String): Boolean {
        val c = callFor(cid) ?: return false
        if (c.details.state == Call.STATE_RINGING) c.reject(false, null) else c.disconnect()
        return true
    }

    /** End a call; a call still ringing is rejected (disconnect would only silence it on some builds). */
    fun end(cid: String): Boolean {
        val c = callFor(cid) ?: return false
        if (c.details.state == Call.STATE_RINGING) c.reject(false, null) else c.disconnect()
        Log.i(TAG, "end requested for $cid (${stateName(c.details.state)})")
        return true
    }

    fun hold(cid: String, on: Boolean) = calls[cid]?.let { if (on) it.hold() else it.unhold() } != null

    fun dtmf(cid: String, digit: Char): Boolean {
        val c = calls[cid] ?: calls.values.firstOrNull { it.details.state == Call.STATE_ACTIVE } ?: return false
        if (digit !in "0123456789*#") return false
        c.playDtmfTone(digit)
        main.postDelayed({ c.stopDtmfTone() }, 180)
        return true
    }

    fun mute(on: Boolean) = service?.setMuted(on) != null
    fun isMuted(): Boolean = service?.callAudioState?.isMuted == true

    fun speaker(on: Boolean) =
        service?.setAudioRoute(if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_WIRED_OR_EARPIECE) != null

    /** Places a real cellular call. Returns an error string, or null on success. */
    @SuppressLint("MissingPermission")
    fun dial(ctx: Context, number: String, sub: Int?): String? {
        val clean = number.filter { it.isDigit() || it in "+*#," }
        if (clean.isEmpty()) return "empty number"
        val extras = Bundle()
        sub?.let { subId ->
            ctx.getSystemService(TelecomManager::class.java)?.callCapablePhoneAccounts
                ?.firstOrNull { it.id.toIntOrNull() == subId }
                ?.let { extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, it) }
        }
        return try {
            ctx.getSystemService(TelecomManager::class.java).placeCall(Uri.fromParts("tel", clean, null), extras)
            null
        } catch (t: Throwable) {
            t.message ?: t.javaClass.simpleName
        }
    }

    /** True when this app is the default phone app (required for InCallService to see live calls). */
    fun isDefaultDialer(ctx: Context): Boolean =
        ctx.getSystemService(TelecomManager::class.java)?.defaultDialerPackage == ctx.packageName

    /** Intent that opens the system "set as default phone app" prompt (RoleManager, API 29+). */
    fun defaultDialerIntent(ctx: Context): Intent? {
        val rm = ctx.getSystemService(RoleManager::class.java) ?: return null
        if (!rm.isRoleAvailable(RoleManager.ROLE_DIALER)) return null
        return rm.createRequestRoleIntent(RoleManager.ROLE_DIALER)
    }
}

/** Default-dialer in-call service: owns call control; the Flutter UI is the on-device call screen. */
class SimBridgeInCallService : InCallService() {
    override fun onCreate() {
        super.onCreate()
        CallRegistry.service = this
        Log.i(CallRegistry.TAG, "in-call service created")
    }

    override fun onDestroy() {
        CallRegistry.service = null
        super.onDestroy()
    }

    override fun onCallAdded(call: Call) {
        Log.i(CallRegistry.TAG, "call added: ${call.details.handle?.schemeSpecificPart} state=${CallRegistry.stateName(call.details.state)}")
        CallRegistry.added(call)
        // Bring the Flutter UI to the front so the user sees the call screen.
        runCatching {
            val i = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            i?.let { startActivity(it) }
        }
    }

    override fun onCallRemoved(call: Call) {
        CallRegistry.removed(call)
    }
}
