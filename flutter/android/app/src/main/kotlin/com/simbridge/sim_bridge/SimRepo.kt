package com.simbridge.sim_bridge

import android.annotation.SuppressLint
import android.app.role.RoleManager
import android.content.Context
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.provider.Settings
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager

/** SIMs, phone accounts and the status document. Port of Tether's `data/DeviceRepo.kt` (SimRepo part). */
class SimRepo(private val ctx: Context) {
    private val sm get() = ctx.getSystemService(SubscriptionManager::class.java)
    private val tm get() = ctx.getSystemService(TelephonyManager::class.java)
    private val telecom get() = ctx.getSystemService(TelecomManager::class.java)

    @SuppressLint("MissingPermission")
    fun sims(): List<Map<String, Any?>> = try {
        sm.activeSubscriptionInfoList?.map { s ->
            mapOf<String, Any?>(
                "sub" to s.subscriptionId,
                "slot" to s.simSlotIndex,
                "name" to (s.displayName?.toString() ?: ""),
                "carrier" to (s.carrierName?.toString() ?: ""),
                "num" to (s.number ?: ""),
            )
        } ?: emptyList()
    } catch (_: Throwable) { emptyList() }

    @SuppressLint("MissingPermission")
    fun resolveSub(sub: Int?, forSms: Boolean): Int? {
        val active = try { sm.activeSubscriptionInfoList?.map { it.subscriptionId } ?: emptyList() } catch (_: Throwable) { emptyList() }
        if (sub != null && sub in active) return sub
        val def = if (forSms) SubscriptionManager.getDefaultSmsSubscriptionId() else SubscriptionManager.getDefaultVoiceSubscriptionId()
        if (def != SubscriptionManager.INVALID_SUBSCRIPTION_ID && def in active) return def
        return active.firstOrNull() ?: sub
    }

    @SuppressLint("MissingPermission")
    fun accountFor(sub: Int?): PhoneAccountHandle? {
        val s = resolveSub(sub, forSms = false) ?: return null
        return try {
            telecom.callCapablePhoneAccounts.firstOrNull { tm.getSubscriptionId(it) == s }
        } catch (_: Throwable) {
            null
        }
    }

    @SuppressLint("MissingPermission")
    fun subFor(handle: PhoneAccountHandle?): Int? = try {
        handle?.let { tm.getSubscriptionId(it).takeIf { s -> s != SubscriptionManager.INVALID_SUBSCRIPTION_ID } }
    } catch (_: Throwable) {
        null
    }

    @SuppressLint("MissingPermission")
    fun subForAccountId(accountId: String?): Int? = try {
        accountId?.let { telecom.callCapablePhoneAccounts.firstOrNull { h -> h.id == it }?.let { subFor(it) } }
    } catch (_: Throwable) {
        null
    }

    /**
     * The status document (`HubData.statusJson`): device, battery, SIMs, default subscription, dialer role,
     * helper state, Wi-Fi, wireless debugging. `helper` is filled in by the audio plugin (it owns the helper);
     * pass an empty map when the helper state is unknown.
     */
    fun status(helper: Map<String, Any?> = emptyMap()): Map<String, Any?> {
        val bat = ctx.registerReceiver(null, IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
        val level = bat?.let { it.getIntExtra(BatteryManager.EXTRA_LEVEL, 0) * 100 / maxOf(1, it.getIntExtra(BatteryManager.EXTRA_SCALE, 100)) } ?: 0
        val plugged = (bat?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        val wifi = cm.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val def = SubscriptionManager.getDefaultVoiceSubscriptionId().takeIf { it != SubscriptionManager.INVALID_SUBSCRIPTION_ID }
        val m = mutableMapOf<String, Any?>(
            "device" to (Settings.Global.getString(ctx.contentResolver, "device_name") ?: android.os.Build.MODEL),
            "battery" to level,
            "charging" to plugged,
            "sims" to sims(),
            "dialer" to isDialer(),
            "helper" to helper,
            "wifi" to wifi,
            "adbWifi" to (Settings.Global.getInt(ctx.contentResolver, "adb_wifi_enabled", 0) == 1),
        )
        def?.let { m["defaultSub"] = it }
        return m
    }

    fun isDialer() = ctx.getSystemService(RoleManager::class.java)?.isRoleHeld(RoleManager.ROLE_DIALER) == true
}

/** Block / mute lists, stored in SharedPreferences. Port of Tether's `data/Lists.kt`. */
class ListsRepo(private val ctx: Context) {
    private val prefs = ctx.getSharedPreferences("lists", Context.MODE_PRIVATE)

    fun blocked(): List<String> {
        val own = own()
        return own // the system block list is not readable; our own list is what the screening service enforces
    }

    fun isBlocked(number: String): Boolean {
        val key = numberKey(number)
        return key.isNotEmpty() && own().any { numberKey(it) == key }
    }

    /** Returns "tether" on success, or an error string. */
    fun setBlocked(number: String, on: Boolean): String {
        val key = numberKey(number)
        if (key.isEmpty()) return "error: empty number"
        val own = own().filter { numberKey(it) != key }.toMutableList()
        if (on) own.add(number)
        prefs.edit().putString("blocked", org.json.JSONArray(own).toString()).apply()
        return "tether"
    }

    private fun own(): List<String> = try {
        val a = org.json.JSONArray(prefs.getString("blocked", "[]"))
        buildList { for (i in 0 until a.length()) a.optString(i).takeIf { it.isNotEmpty() }?.let { add(it) } }
    } catch (_: Throwable) { emptyList() }

    fun muted(): List<Long> = try {
        val a = org.json.JSONArray(prefs.getString("muted", "[]"))
        buildList { for (i in 0 until a.length()) add(a.optLong(i)) }
    } catch (_: Throwable) { emptyList() }

    fun isMuted(thread: Long) = thread in muted()

    fun setMuted(thread: Long, on: Boolean) {
        val m = muted().filter { it != thread }.toMutableList()
        if (on) m.add(thread)
        prefs.edit().putString("muted", org.json.JSONArray(m).toString()).apply()
    }

    /** The lists document (`HubData.listsJson`): `{'blocked': [...], 'muted': [...], 'system': false}`. */
    fun json(): Map<String, Any?> = mapOf(
        "blocked" to blocked(),
        "muted" to muted(),
        "system" to false,
    )
}
