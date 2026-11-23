package com.simbridge.helper

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Downlink (far-end voice) capture. */
interface Capture {
    val name: String
    /** Fills [buf] with mono PCM16; returns samples read or < 0. */
    fun read(buf: ShortArray): Int
    fun bufferFrames(): Int
    /** Audio captured by the system but not read by us yet, in frames (-1 if unknown). */
    fun backlogFrames(): Int = -1
    fun stop()
}

/** Uplink (what the far end hears) injection. */
interface Inject {
    val name: String
    fun write(buf: ShortArray, n: Int = buf.size)
    fun routedTo(): String
    fun bufferFrames(): Int
    fun latencyMs(): Int
    /** Written but not yet played, in frames. */
    fun queuedFrames(): Int = -1
    fun stop()
}

@SuppressLint("MissingPermission", "PrivateApi", "DiscouragedPrivateApi", "WrongConstant")
object CallAudio {
    val captureMethods = listOf("intercept", "voice_downlink", "telephony_rx", "voice_call")
    val injectMethods = listOf("intercept", "telephony_tx", "policy_mix")

    private val am get() = ShellEnv.audioManager

    fun format(rate: Int): AudioFormat = AudioFormat.Builder()
        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
        .setSampleRate(rate)
        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
        .build()

    private fun outFormat(rate: Int): AudioFormat = AudioFormat.Builder()
        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
        .setSampleRate(rate)
        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
        .build()

    fun telephonyDevice(output: Boolean): AudioDeviceInfo? =
        am.getDevices(if (output) AudioManager.GET_DEVICES_OUTPUTS else AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull { it.type == AudioDeviceInfo.TYPE_TELEPHONY }

    fun isInterceptable(): Boolean? = try {
        AudioManager::class.java.getMethod("isPstnCallAudioInterceptable").invoke(am) as Boolean
    } catch (t: Throwable) {
        null
    }

    // ---------------------------------------------------------------- capture

    fun openCapture(method: String, rate: Int): Capture {
        val rec: AudioRecord = when (method) {
            "intercept" -> AudioManager::class.java
                .getMethod("getCallDownlinkExtractionAudioRecord", AudioFormat::class.java)
                .invoke(am, format(rate)) as AudioRecord
            "voice_downlink" -> buildRecord(MediaRecorder.AudioSource.VOICE_DOWNLINK, rate)
            "voice_call" -> buildRecord(MediaRecorder.AudioSource.VOICE_CALL, rate)
            "voice_uplink" -> buildRecord(MediaRecorder.AudioSource.VOICE_UPLINK, rate)
            "telephony_rx" -> buildRecord(MediaRecorder.AudioSource.DEFAULT, rate).also { r ->
                val dev = telephonyDevice(false) ?: run { r.release(); error("no telephony input device") }
                r.preferredDevice = dev
            }
            else -> error("unknown capture method $method")
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release(); error("AudioRecord not initialized")
        }
        rec.startRecording()
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            rec.release(); error("startRecording failed")
        }
        return object : Capture {
            override val name = method
            private var readFrames = 0L
            private val ts = android.media.AudioTimestamp()
            override fun read(buf: ShortArray) = rec.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING).also { if (it > 0) readFrames += it }
            override fun bufferFrames() = rec.bufferSizeInFrames
            override fun backlogFrames(): Int {
                if (rec.getTimestamp(ts, android.media.AudioTimestamp.TIMEBASE_MONOTONIC) != AudioRecord.SUCCESS) return -1
                val now = System.nanoTime()
                val captured = ts.framePosition + (now - ts.nanoTime) * rec.sampleRate / 1_000_000_000L
                return (captured - readFrames).toInt()
            }
            override fun stop() { runCatching { rec.stop() }; rec.release() }
        }
    }

    private fun buildRecord(source: Int, rate: Int): AudioRecord {
        val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val b = AudioRecord.Builder()
            .setAudioSource(source)
            .setAudioFormat(format(rate))
            .setBufferSizeInBytes(maxOf(min, rate / 25 * 2)) // ≥ 40 ms; we read every 20 ms
        if (Build.VERSION.SDK_INT >= 31) b.setContext(ShellEnv.context)
        return b.build()
    }

    // ---------------------------------------------------------------- inject

    fun openInject(method: String, rate: Int): Inject {
        var policy: Any? = null
        val track: AudioTrack = when (method) {
            "intercept" -> AudioManager::class.java
                .getMethod("getCallUplinkInjectionAudioTrack", AudioFormat::class.java)
                .invoke(am, outFormat(rate)) as AudioTrack
            "telephony_tx" -> buildTrack(rate, AudioAttributes.USAGE_MEDIA).also { t ->
                val dev = telephonyDevice(true) ?: run { t.release(); error("no telephony output device") }
                if (!t.setPreferredDevice(dev)) { t.release(); error("setPreferredDevice refused") }
            }
            "policy_mix" -> {
                val dev = telephonyDevice(true) ?: error("no telephony output device")
                policy = registerUplinkPolicy(dev, rate)
                buildTrack(rate, AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING)
            }
            else -> error("unknown inject method $method")
        }
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release(); policy?.let { unregisterPolicy(it) }; error("AudioTrack not initialized")
        }
        // Cap the playback buffer to ~40 ms (2 frames) to keep uplink latency low.
        runCatching { track.bufferSizeInFrames = maxOf(rate / 25, track.bufferSizeInFrames.coerceAtMost(rate / 25)) }
        track.play()
        val p = policy
        return object : Inject {
            override val name = method
            private var written = 0L
            override fun write(buf: ShortArray, n: Int) { val w = track.write(buf, 0, n, AudioTrack.WRITE_BLOCKING); if (w > 0) written += w }
            override fun queuedFrames(): Int = (written - (track.playbackHeadPosition.toLong() and 0xffffffffL)).toInt()
            override fun routedTo(): String = track.routedDevice?.let { "${it.type}:${it.productName}" } ?: "none"
            override fun bufferFrames() = track.bufferSizeInFrames
            override fun latencyMs(): Int = try {
                AudioTrack::class.java.getMethod("getLatency").invoke(track) as Int
            } catch (t: Throwable) { -1 }
            override fun stop() {
                runCatching { track.stop() }
                track.release()
                p?.let { unregisterPolicy(it) }
            }
        }
    }

    private fun buildTrack(rate: Int, usage: Int): AudioTrack {
        val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        return AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(usage)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(outFormat(rate))
            .setBufferSizeInBytes(min)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
    }

    /** Dynamic audio policy: route our signalling-usage track to Telephony Tx (needs MODIFY_AUDIO_ROUTING). */
    private fun registerUplinkPolicy(dev: AudioDeviceInfo, rate: Int): Any {
        val ruleB = Class.forName("android.media.audiopolicy.AudioMixingRule\$Builder")
        val ruleClass = Class.forName("android.media.audiopolicy.AudioMixingRule")
        val matchUsage = ruleClass.getField("RULE_MATCH_ATTRIBUTE_USAGE").getInt(null)
        val rb = ruleB.getConstructor().newInstance()
        ruleB.getMethod("addMixRule", Int::class.javaPrimitiveType, Any::class.java).invoke(rb, matchUsage,
            AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING).build())
        val rule = ruleB.getMethod("build").invoke(rb)
        val mixClass = Class.forName("android.media.audiopolicy.AudioMix")
        val mixB = Class.forName("android.media.audiopolicy.AudioMix\$Builder")
        val mb = mixB.getConstructor(ruleClass).newInstance(rule)
        mixB.getMethod("setFormat", AudioFormat::class.java).invoke(mb, outFormat(rate))
        mixB.getMethod("setRouteFlags", Int::class.javaPrimitiveType).invoke(mb, mixClass.getField("ROUTE_FLAG_RENDER").getInt(null))
        mixB.getMethod("setDevice", AudioDeviceInfo::class.java).invoke(mb, dev)
        val mix = mixB.getMethod("build").invoke(mb)
        val polB = Class.forName("android.media.audiopolicy.AudioPolicy\$Builder")
        val pb = polB.getConstructor(android.content.Context::class.java).newInstance(ShellEnv.context)
        polB.getMethod("addMix", mixClass).invoke(pb, mix)
        val policy = polB.getMethod("build").invoke(pb)
        val res = AudioManager::class.java.getMethod("registerAudioPolicy", policy.javaClass).invoke(am, policy) as Int
        if (res != 0) error("registerAudioPolicy returned $res")
        return policy
    }

    private fun unregisterPolicy(policy: Any) {
        runCatching { AudioManager::class.java.getMethod("unregisterAudioPolicy", policy.javaClass).invoke(am, policy) }
    }

    // ---------------------------------------------------------------- probe & self-test

    fun probe(rate: Int = 16000): JSONObject {
        val o = JSONObject()
        o.put("sdk", Build.VERSION.SDK_INT).put("model", Build.MODEL).put("uid", android.os.Process.myUid())
        o.put("mode", am.mode).put("interceptable", isInterceptable())
        o.put("outputs", devices(AudioManager.GET_DEVICES_OUTPUTS)).put("inputs", devices(AudioManager.GET_DEVICES_INPUTS))
        val caps = JSONArray()
        for (m in captureMethods + "voice_uplink") {
            val r = JSONObject().put("method", m)
            try {
                val c = openCapture(m, rate)
                val buf = ShortArray(rate / 50)
                var total = 0; var energy = 0.0
                repeat(10) { val n = c.read(buf); if (n > 0) { total += n; energy += rms(buf, n) } }
                c.stop()
                r.put("ok", true).put("samples", total).put("rms", energy / 10)
            } catch (t: Throwable) {
                r.put("ok", false).put("error", describe(t))
            }
            caps.put(r)
        }
        o.put("capture", caps)
        val injs = JSONArray()
        for (m in injectMethods) {
            val r = JSONObject().put("method", m)
            try {
                val i = openInject(m, rate)
                val tone = tone(1000.0, rate, rate / 50)
                repeat(5) { i.write(tone) }
                r.put("ok", true).put("routed", i.routedTo())
                i.stop()
            } catch (t: Throwable) {
                r.put("ok", false).put("error", describe(t))
            }
            injs.put(r)
        }
        o.put("inject", injs)
        return o
    }

    /**
     * During a live call: play a 1 kHz tone with each inject method while capturing VOICE_UPLINK,
     * and look for the tone with a Goertzel filter. A hit means the far end hears us.
     */
    fun selfTest(rate: Int = 16000): JSONObject {
        val res = JSONArray()
        var chosen: String? = null
        val frame = rate / 50
        for (m in injectMethods) {
            val r = JSONObject().put("name", "inject:$m")
            var inj: Inject? = null
            var cap: Capture? = null
            try {
                cap = openCapture("voice_uplink", rate)
                val buf = ShortArray(frame)
                var base = 0.0
                repeat(10) { val n = cap.read(buf); if (n > 0) base += goertzel(buf, n, 1000.0, rate) }
                inj = openInject(m, rate)
                val tone = tone(1000.0, rate, frame, amp = 8000.0)
                var hit = 0.0
                repeat(25) {
                    inj.write(tone)
                    val n = cap.read(buf)
                    if (it >= 10 && n > 0) hit += goertzel(buf, n, 1000.0, rate)
                }
                val ratio = (hit / 15) / (base / 10 + 1e-3)
                val ok = ratio > 20
                r.put("ok", ok).put("note", "tone/base=%.1f routed=%s".format(ratio, inj.routedTo()))
                if (ok && chosen == null) chosen = m
            } catch (t: Throwable) {
                r.put("ok", false).put("note", describe(t))
            } finally {
                inj?.stop(); cap?.stop()
            }
            res.put(r)
        }
        for (m in captureMethods) {
            val r = JSONObject().put("name", "capture:$m")
            try {
                val c = openCapture(m, rate)
                val buf = ShortArray(frame); var e = 0.0
                repeat(25) { val n = c.read(buf); if (n > 0) e += rms(buf, n) }
                c.stop()
                r.put("ok", e / 25 > 1.0).put("note", "rms=%.1f".format(e / 25))
            } catch (t: Throwable) {
                r.put("ok", false).put("note", describe(t))
            }
            res.put(r)
        }
        return JSONObject().put("methods", res).apply { chosen?.let { put("chosen", it) } }
    }

    private fun devices(flag: Int) = JSONArray().apply {
        for (d in am.getDevices(flag)) put(JSONObject().put("id", d.id).put("type", d.type).put("name", d.productName.toString())
            .put("address", d.address))
    }

    fun describe(t: Throwable): String {
        val root = generateSequence(t) { it.cause }.last()
        return "${root.javaClass.simpleName}: ${root.message}"
    }

    fun rms(b: ShortArray, n: Int): Double {
        var s = 0.0
        for (i in 0 until n) s += b[i].toDouble() * b[i]
        return sqrt(s / maxOf(1, n))
    }

    fun tone(freq: Double, rate: Int, n: Int, amp: Double = 6000.0, phase0: Int = 0) =
        ShortArray(n) { (amp * sin(2 * PI * freq * (it + phase0) / rate)).toInt().toShort() }

    fun goertzel(b: ShortArray, n: Int, freq: Double, rate: Int): Double {
        val k = 2 * cos(2 * PI * freq / rate)
        var s1 = 0.0; var s2 = 0.0
        for (i in 0 until n) { val s0 = b[i] + k * s1 - s2; s2 = s1; s1 = s0 }
        return sqrt(maxOf(0.0, s1 * s1 + s2 * s2 - k * s1 * s2)) / n
    }

    /** Samsung phones have vendor parameters that mute their own earpiece and microphone during a call. */
    val hasSamsungCallMute: Boolean get() = Build.MANUFACTURER.equals("samsung", ignoreCase = true)

    /**
     * Mutes / restores the Android phone's own earpiece (received voice) and microphone for a bridged call.
     * Samsung: its vendor audio parameters (the ones its Text Call feature sets), rx/tx control mode 1 = muted.
     * Other phones have no known equivalent the shell may set: the call is still bridged, and the phone's own
     * earpiece and microphone stay on (keep it in a bag or pocket, volume down).
     */
    fun localCallAudio(muted: Boolean, errors: org.json.JSONArray): String {
        if (!hasSamsungCallMute) return "not available on this phone"
        val v = if (muted) "1" else "0"
        return try {
            am.setParameters("l_voice_rx_control_mode=$v")
            am.setParameters("l_voice_tx_control_mode=$v")
            "rx=$v tx=$v"
        } catch (t: Throwable) {
            errors.put("local mute ${describe(t)}"); "failed"
        }
    }
}
