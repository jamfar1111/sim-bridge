package com.simbridge.helper

import android.annotation.SuppressLint
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.media.AudioManager
import android.os.Looper
import android.os.Process

/**
 * Minimal Android environment for a process started with `app_process` as the shell user.
 * There is no Application here, so we build a system context and wrap it with an identity
 * the audio server accepts ("com.android.shell", uid 2000).
 */
@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
object ShellEnv {
    const val SHELL_PACKAGE = "com.android.shell"

    @Volatile private var ctx: Context? = null

    fun init() {
        if (ctx != null) return
        if (Looper.getMainLooper() == null) {
            @Suppress("DEPRECATION")
            Looper.prepareMainLooper()
        }
        val atClass = Class.forName("android.app.ActivityThread")
        val ctor = atClass.getDeclaredConstructor().apply { isAccessible = true }
        val thread = ctor.newInstance()
        atClass.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, thread)
        // Some vendor audio code asks the current ActivityThread for application info.
        try {
            val appBindDataClass = Class.forName("android.app.ActivityThread\$AppBindData")
            val bind = appBindDataClass.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
            val ai = android.content.pm.ApplicationInfo().apply { packageName = SHELL_PACKAGE; uid = Process.myUid() }
            appBindDataClass.getDeclaredField("appInfo").apply { isAccessible = true }.set(bind, ai)
            atClass.getDeclaredField("mBoundApplication").apply { isAccessible = true }.set(thread, bind)
        } catch (t: Throwable) {
            log("AppBindData workaround skipped: $t")
        }
        // Samsung's display sandboxing asks ActivityThread for its configuration while creating the system context.
        try {
            val ccClass = Class.forName("android.app.ConfigurationController")
            val internal = Class.forName("android.app.ActivityThreadInternal")
            val cc = ccClass.getDeclaredConstructor(internal).apply { isAccessible = true }.newInstance(thread)
            atClass.getDeclaredField("mConfigurationController").apply { isAccessible = true }.set(thread, cc)
        } catch (t: Throwable) {
            log("ConfigurationController workaround skipped: $t")
        }
        val system = atClass.getDeclaredMethod("getSystemContext").apply { isAccessible = true }.invoke(thread) as Context
        ctx = ShellContext(system)
    }

    val context: Context get() = ctx ?: run { init(); ctx!! }

    /** AudioManager bound to our shell identity (the public getSystemService would cache the system one). */
    val audioManager: AudioManager by lazy {
        try {
            AudioManager::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }
                .newInstance(context)
        } catch (t: Throwable) {
            context.getSystemService(AudioManager::class.java)
        }
    }

    fun log(msg: String) = System.err.println("[simbridge-helper] $msg")

    private class ShellContext(base: Context) : ContextWrapper(base) {
        override fun getPackageName() = SHELL_PACKAGE
        override fun getOpPackageName() = SHELL_PACKAGE
        override fun getAttributionSource(): AttributionSource =
            AttributionSource.Builder(2000).setPackageName(SHELL_PACKAGE).build()
        override fun getApplicationContext(): Context = this
    }
}
