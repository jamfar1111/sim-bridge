package com.simbridge.sim_bridge

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Mirrors `sim_bridge.log` into the public Downloads folder so the
/// user can reach it WITHOUT the Files app's Android/data folder
/// (Android 13+ refuses to show Android/data contents on-device) and
/// WITHOUT opening the app (which may crash on launch).
///
/// The copy lands in Files → Downloads as `sim_bridge.log`, where it
/// can be opened and shared. It uses MediaStore, which needs no
/// permission for the app's own files (minSdk 31, MediaStore
/// Downloads exists since API 29). A previous copy with the same
/// name is deleted first, so Downloads shows exactly one file.
///
/// Every entry point is best-effort and never throws: logging must
/// never become a crash cause itself.
object LogMirror {
    const val FILE_NAME = "sim_bridge.log"

    /// Copies the current log file to Downloads. Returns true when a
    /// copy was written, false when there is no log yet or the
    /// MediaStore write failed.
    fun mirrorToDownloads(context: Context): Boolean {
        return try {
            val dir = context.getExternalFilesDir(null) ?: return false
            val file = File(dir, FILE_NAME)
            if (!file.exists()) return false
            writeToDownloads(context, file.readBytes())
        } catch (_: Throwable) {
            false
        }
    }

    private fun writeToDownloads(context: Context, bytes: ByteArray): Boolean {
        return try {
            val resolver = context.contentResolver
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            // Replace, don't duplicate: delete our previous copy.
            val old = resolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                arrayOf(FILE_NAME),
                null,
            )
            old?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    resolver.delete(
                        Uri.withAppendedPath(collection, id.toString()),
                        null,
                        null,
                    )
                }
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, FILE_NAME)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/")
            }
            val uri = resolver.insert(collection, values) ?: return false
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: return false
            true
        } catch (_: Throwable) {
            false
        }
    }
}

/// MethodChannel bridge (`com.simbridge/log`, method `mirrorLog`) so
/// the Dart logger can ask for a Downloads mirror. Registered from
/// MainActivity like the other hand-written plugins.
class LogMirrorPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding

    override fun onAttachedToEngine(
        binding: FlutterPlugin.FlutterPluginBinding,
    ) {
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, "com.simbridge/log")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "mirrorLog" -> {
                val ok = try {
                    LogMirror.mirrorToDownloads(binding.applicationContext)
                } catch (_: Throwable) {
                    false
                }
                result.success(ok)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(
        binding: FlutterPlugin.FlutterPluginBinding,
    ) {
        channel.setMethodCallHandler(null)
    }
}
