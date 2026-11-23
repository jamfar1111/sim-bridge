package com.simbridge.sim_bridge

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.android.AdbMdns
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.math.BigInteger
import java.net.InetAddress
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * ADB client to the phone's own adbd over Wireless debugging (TLS, loopback/Wi-Fi), via libadb-android.
 * Our RSA key + self-signed certificate are what adbd remembers after the one-time pairing.
 */
class Adb private constructor(private val ctx: Context) : AbsAdbConnectionManager() {
    private val keyFile = File(ctx.filesDir, "adb_key.pk8")
    private val certFile = File(ctx.filesDir, "adb_cert.der")
    private val key: PrivateKey
    private val cert: Certificate

    init {
        setApi(Build.VERSION.SDK_INT)
        setTimeout(10, TimeUnit.SECONDS)
        if (!keyFile.exists() || !certFile.exists()) generate()
        key = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(keyFile.readBytes()))
        cert = CertificateFactory.getInstance("X.509").generateCertificate(certFile.inputStream())
    }

    private fun generate() {
        val kp = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val name = X500Name("CN=Tether")
        val now = System.currentTimeMillis()
        val builder = JcaX509v3CertificateBuilder(name, BigInteger.valueOf(now), Date(now - 86_400_000),
            Date(now + 20L * 365 * 86_400_000), name, kp.public)
        val signer = JcaContentSignerBuilder("SHA256withRSA").build(kp.private)
        val c = JcaX509CertificateConverter().setProvider(BouncyCastleProvider()).getCertificate(builder.build(signer))
        keyFile.writeBytes(kp.private.encoded)
        certFile.writeBytes(c.encoded)
    }

    override fun getPrivateKey() = key
    override fun getCertificate() = cert
    override fun getDeviceName() = "simbridge"

    /** Pairs with the 6-digit code shown in Settings › Wireless debugging › Pair device with pairing code. */
    fun pairWithCode(code: String): Boolean {
        val (host, port) = discover(AdbMdns.SERVICE_TYPE_TLS_PAIRING, 15)
            ?: throw IllegalStateException("pairing service not found; keep the pairing dialog open")
        Log.i(TAG, "pairing with $host:$port")
        return pair(host, port, code.trim())
    }

    @Synchronized fun ensureConnected(): Boolean {
        if (isConnected) return true
        return autoConnect(ctx, 10_000)
    }

    /** Runs a shell command and returns its output (stdout + stderr). */
    @Synchronized fun shell(cmd: String): String {
        if (!ensureConnected()) throw IllegalStateException("adb not connected")
        // "shell,raw:" runs without a PTY, so a backgrounded helper is not hung up when the stream closes.
        openStream("shell,raw:$cmd").use { s ->
            val input = s.openInputStream()
            val out = StringBuilder()
            val buf = ByteArray(4096)
            while (true) {
                val n = try { input.read(buf) } catch (e: Exception) { -1 }
                if (n < 0) break
                out.append(String(buf, 0, n))
            }
            return out.toString()
        }
    }

    private fun discover(type: String, timeoutSec: Long): Pair<String, Int>? {
        var found: Pair<String, Int>? = null
        val latch = CountDownLatch(1)
        val mdns = AdbMdns(ctx, type) { addr: InetAddress?, port: Int ->
            if (addr != null && port > 0) { found = (addr.hostAddress ?: "127.0.0.1") to port; latch.countDown() }
        }
        mdns.start()
        latch.await(timeoutSec, TimeUnit.SECONDS)
        mdns.stop()
        return found
    }

    companion object {
        const val TAG = "Tether"
        @Volatile private var instance: Adb? = null
        fun get(ctx: Context): Adb = instance ?: synchronized(this) {
            instance ?: Adb(ctx.applicationContext).also { instance = it }
        }

        /** Drops the current connection (it may be hung on a restarted adbd); the next get() starts fresh. */
        fun reset() {
            val old = synchronized(this) { instance.also { instance = null } } ?: return
            Thread({ runCatching { old.close() } }, "adb-close").apply { isDaemon = true }.start()
        }

        fun hasSecureSettings(ctx: Context) =
            ctx.checkSelfPermission(android.Manifest.permission.WRITE_SECURE_SETTINGS) == android.content.pm.PackageManager.PERMISSION_GRANTED

        /** Turns Wireless debugging on (needs WRITE_SECURE_SETTINGS and Wi-Fi). */
        fun enableWirelessDebugging(ctx: Context): Boolean = try {
            Settings.Global.putInt(ctx.contentResolver, "adb_wifi_enabled", 1)
        } catch (e: SecurityException) {
            false
        }

        /** After pairing: grant ourselves what we need through adb once. */
        fun bootstrap(ctx: Context): String {
            val adb = get(ctx)
            val pkg = ctx.packageName
            val sb = StringBuilder()
            sb.append(adb.shell("pm grant $pkg android.permission.WRITE_SECURE_SETTINGS 2>&1"))
            for (p in listOf("READ_SMS", "RECEIVE_SMS", "SEND_SMS", "READ_CONTACTS", "WRITE_CONTACTS", "READ_CALL_LOG", "WRITE_CALL_LOG",
                "READ_PHONE_STATE", "READ_PHONE_NUMBERS", "CALL_PHONE", "ANSWER_PHONE_CALLS", "BLUETOOTH_CONNECT",
                "BLUETOOTH_ADVERTISE", "POST_NOTIFICATIONS")) {
                sb.append(adb.shell("pm grant $pkg android.permission.$p 2>&1"))
            }
            sb.append(adb.shell("cmd deviceidle whitelist +$pkg 2>&1"))
            sb.append(allowSmsWrite(ctx))
            return sb.toString()
        }

        /**
         * Lets Tether mark messages as read although it is not the default SMS app: the WRITE_SMS app-op,
         * which only the shell may set. Cheap and idempotent, so it is repeated whenever the helper starts.
         */
        fun allowSmsWrite(ctx: Context): String = try {
            get(ctx).shell("appops set ${ctx.packageName} WRITE_SMS allow 2>&1")
        } catch (t: Throwable) {
            "appops: ${t.message}"
        }

        // ------------------------------------------------------------------ notification flow

        const val NOTIF_ADB = 30
        const val KEY_CODE = "code"
        /** Notification channel for setup flows; created by the audio plugin (see CallAudioPlugin). */
        const val CH_SETUP = "setup"

        fun showPairingNotification(ctx: Context, text: String = "Open Developer options › Wireless debugging › Pair device with pairing code, then type the 6-digit code here.") {
            val input = RemoteInput.Builder(KEY_CODE).setLabel("Pairing code").build()
            val pi = PendingIntent.getBroadcast(ctx, 7, Intent(ctx, AdbPairingReceiver::class.java),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val action = Notification.Action.Builder(null, "Enter code", pi)
                .addRemoteInput(input).build()
            val n = Notification.Builder(ctx, CH_SETUP)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Wireless debugging pairing")
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .addAction(action)
                .setOngoing(true)
                .build()
            ctx.getSystemService(NotificationManager::class.java).notify(NOTIF_ADB, n)
        }

        fun updateNotification(ctx: Context, text: String, done: Boolean) {
            if (!done) { showPairingNotification(ctx, text); return }
            val n = Notification.Builder(ctx, CH_SETUP).setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Wireless debugging pairing").setContentText(text).setAutoCancel(true).build()
            ctx.getSystemService(NotificationManager::class.java).notify(NOTIF_ADB, n)
        }
    }
}

class AdbPairingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val code = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(Adb.KEY_CODE)?.toString()?.filter { it.isDigit() }
        if (code.isNullOrEmpty()) return
        Adb.updateNotification(context, "Pairing…", false)
        val pending = goAsync()
        Thread {
            try {
                Adb.get(context).pairWithCode(code)
                context.getSharedPreferences("sim_bridge", Context.MODE_PRIVATE).edit().putBoolean("adb_paired", true).apply()
                Adb.bootstrap(context)
                Adb.updateNotification(context, "Paired with Wireless debugging. Starting the audio helper…", true)
                // The audio plugin owns the helper: kick it now that pairing succeeded.
                CallAudioPlugin.kickHelper(context)
            } catch (t: Throwable) {
                Log.w(Adb.TAG, "pairing failed", t)
                Adb.updateNotification(context, "Pairing failed: ${t.message ?: t.javaClass.simpleName}", false)
            } finally {
                pending.finish()
            }
        }.start()
    }
}
