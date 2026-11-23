package com.simbridge.sim_bridge

import android.content.Context
import android.os.Bundle
import android.os.Process
import io.flutter.app.FlutterApplication
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/// The app's Application: installs the uncaught-exception handler
/// as early as possible (attachBaseContext, before any activity),
/// so even a crash during Flutter engine startup lands in the log
/// file. The handler writes `FATAL …` lines to the SAME file the
/// Dart logger uses (`<external files dir>/sim_bridge.log`, with
/// the same 2 MB rotation), then chains to the previous handler so
/// Android still shows the crash dialog and kills the process.
///
/// [installSimBridgeCrashHandler] is also called from
/// `MainActivity.onCreate` as a second net, in case the Application
/// path is ever bypassed.
class SimBridgeApplication : FlutterApplication() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        // Guarded: installing the handler must never crash startup.
        try {
            installSimBridgeCrashHandler(base)
        } catch (_: Throwable) {
        }
    }

    override fun onCreate() {
        super.onCreate()
        try {
            installSimBridgeCrashHandler(this)
        } catch (_: Throwable) {
        }
        // Mirror the previous run's log (if any) into Downloads, so a
        // crash from the last launch is reachable even when this
        // launch crashes again before Dart starts.
        try {
            LogMirror.mirrorToDownloads(this)
        } catch (_: Throwable) {
        }
    }
}

/// Installs the crash handler once; a no-op when already installed.
fun installSimBridgeCrashHandler(context: Context) {
    val current = Thread.getDefaultUncaughtExceptionHandler()
    if (current is SimBridgeCrashHandler) return
    Thread.setDefaultUncaughtExceptionHandler(
        SimBridgeCrashHandler(context.applicationContext, current)
    )
}

/// Writes the fatal exception to `sim_bridge.log` and chains to the
/// previous handler. Never throws itself: a crashing crash handler
/// would hide the real crash.
class SimBridgeCrashHandler(
    private val context: Context,
    private val previous: Thread.UncaughtExceptionHandler?,
) : Thread.UncaughtExceptionHandler {

    override fun uncaughtException(t: Thread, e: Throwable) {
        try {
            val dir = context.getExternalFilesDir(null)
            if (dir != null) {
                val file = File(dir, "sim_bridge.log")
                if (file.exists() && file.length() > 2L * 1024 * 1024) {
                    val backup = File(dir, "sim_bridge.log.1")
                    if (backup.exists()) backup.delete()
                    file.renameTo(backup)
                }
                val ts = SimpleDateFormat(
                    "yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US
                ).format(Date())
                val sw = StringWriter()
                e.printStackTrace(PrintWriter(sw))
                file.appendText(
                    "FATAL $ts thread=${t.name} " +
                        "${e.javaClass.name}: ${e.message}\n$sw\n",
                    Charsets.UTF_8,
                )
                // Copy the crash into Downloads right away: the app
                // is dying, and this may be the only chance to make
                // the log reachable without opening the app again.
                try {
                    LogMirror.mirrorToDownloads(context)
                } catch (_: Throwable) {
                }
            }
        } catch (_: Throwable) {
            // Never crash the crash handler.
        }
        if (previous != null) {
            previous.uncaughtException(t, e)
        } else {
            // No handler to chain to: kill the process ourselves,
            // or the app would hang instead of crashing.
            Process.killProcess(Process.myPid())
            System.exit(10)
        }
    }
}
