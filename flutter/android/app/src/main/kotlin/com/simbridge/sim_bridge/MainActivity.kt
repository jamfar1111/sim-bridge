package com.simbridge.sim_bridge

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Second net for the crash handler (the Application installs
        // it first, in attachBaseContext). Guarded: this must never
        // crash startup.
        try {
            installSimBridgeCrashHandler(this)
        } catch (_: Throwable) {
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Hand-written native bridges (not pub plugins, so not auto-registered).
        flutterEngine.plugins.add(BlePlugin())
        flutterEngine.plugins.add(TelecomPlugin())
        flutterEngine.plugins.add(SmsPlugin())
        flutterEngine.plugins.add(CallAudioPlugin())
        flutterEngine.plugins.add(LogMirrorPlugin())
    }
}
