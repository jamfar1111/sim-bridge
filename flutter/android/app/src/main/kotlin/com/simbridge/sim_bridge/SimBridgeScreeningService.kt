package com.simbridge.sim_bridge

import android.telecom.Call
import android.telecom.CallScreeningService
import android.util.Log

/**
 * Rejects calls from blocked numbers before they ring anywhere (Android phone, iPhone).
 * Telecom binds the default phone app's screening service for every incoming call.
 *
 * The block list lives in SharedPreferences (`sim_bridge`, key `blocked_numbers`, a string set of
 * normalized numbers); the Dart side writes it through the `setBlockedNumbers` method on the
 * `com.simbridge/telecom` channel whenever the user's list changes (see NATIVE_CHANNELS.md).
 */
class SimBridgeScreeningService : CallScreeningService() {
    override fun onScreenCall(details: Call.Details) {
        val num = details.handle?.schemeSpecificPart ?: ""
        val blocked = details.callDirection == Call.Details.DIRECTION_INCOMING && isBlocked(num)
        if (blocked) Log.i(CallRegistry.TAG, "screening: blocked caller rejected ($num)")
        respondToCall(details, CallResponse.Builder()
            .setDisallowCall(blocked).setRejectCall(blocked).setSkipNotification(blocked)
            .setSkipCallLog(false).build())
    }

    companion object {
        fun isBlocked(ctx: android.content.Context, num: String): Boolean {
            val set = ctx.getSharedPreferences("sim_bridge", android.content.Context.MODE_PRIVATE)
                .getStringSet("blocked_numbers", emptySet()) ?: emptySet()
            val digits = num.filter { it.isDigit() }
            return set.any { it.filter { c -> c.isDigit() } == digits && digits.isNotEmpty() }
        }
    }

    private fun isBlocked(num: String) = isBlocked(applicationContext, num)
}
