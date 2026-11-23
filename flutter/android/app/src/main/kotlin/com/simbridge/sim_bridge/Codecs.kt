package com.simbridge.sim_bridge

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import com.simbridge.sim_bridge.AudioCodec
import com.simbridge.sim_bridge.G711
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Encodes / decodes 20 ms mono PCM16 frames. */
interface VoiceCodec {
    val id: Int
    val name: String
    val rate: Int
    fun encode(pcm: ShortArray): List<ByteArray>
    fun decode(frame: ByteArray): ShortArray?
    /** Packet-loss concealment: a synthetic frame for a missing one (null = play nothing). */
    fun conceal(): ShortArray? = null
    fun release() {}
}

class PcmuCodec : VoiceCodec {
    override val id = AudioCodec.PCMU
    override val name = "pcmu"
    override val rate = 8000
    override fun encode(pcm: ShortArray) = listOf(G711.encode(pcm))
    override fun decode(frame: ByteArray) = G711.decode(frame)
}

/**
 * Opus through Concentus (a pure-Java port of libopus): encode/decode are synchronous calls on the audio
 * thread, so a frame leaves the moment it is encoded. MediaCodec added 5–6 ms of IPC per frame and could
 * hand back a frame one call late (a full extra 20 ms), and it exposes none of the voice settings.
 *
 * Settings: VOIP application (speech-tuned, high-pass + noise shaping), voice signal hint, wideband
 * (the cellular codec is AMR-WB / EVS-WB: nothing above 8 kHz comes down the line), 32 kbps constrained
 * VBR (transparent for wideband speech), complexity 3: paced like a call (one frame per 20 ms, release build compiled ahead of time) it costs 3.7 ms per frame on the Android phone vs 5.2 ms at 5 (codec_bench_paced); speech quality at 32 kbps wideband barely changes. No DTX (a playout buffer reads DTX gaps as underruns)
 * and no in-band FEC: L2CAP is a reliable channel, frames only go missing when we drop them for lateness.
 */
class OpusCodec(override val rate: Int = 16000, val bitrate: Int = 32000, complexity: Int = 3) : VoiceCodec {
    override val id = AudioCodec.OPUS
    override val name = "opus"
    private val frame = rate / 50
    private val enc = io.github.jaredmdobson.concentus.OpusEncoder(rate, 1, io.github.jaredmdobson.concentus.OpusApplication.OPUS_APPLICATION_VOIP).apply {
        setBitrate(bitrate)
        setComplexity(complexity)
        setSignalType(io.github.jaredmdobson.concentus.OpusSignal.OPUS_SIGNAL_VOICE)
        setMaxBandwidth(io.github.jaredmdobson.concentus.OpusBandwidth.OPUS_BANDWIDTH_WIDEBAND)
        setUseVBR(true); setUseConstrainedVBR(true)
        setUseDTX(false); setUseInbandFEC(false)
    }
    private val dec = io.github.jaredmdobson.concentus.OpusDecoder(rate, 1)
    private val out = ByteArray(1275)

    override fun encode(pcm: ShortArray): List<ByteArray> {
        val res = ArrayList<ByteArray>(1)
        var i = 0
        while (i + frame <= pcm.size) {
            val n = enc.encode(pcm, i, frame, out, 0, out.size)
            if (n > 0) res.add(out.copyOf(n))
            i += frame
        }
        return res
    }

    override fun decode(frame: ByteArray): ShortArray? = try {
        val pcm = ShortArray(this.frame * 3)
        val n = dec.decode(frame, 0, frame.size, pcm, 0, this.frame * 3, false)
        if (n > 0) pcm.copyOf(n) else null
    } catch (e: Exception) { null }

    override fun conceal(): ShortArray? = try {
        val pcm = ShortArray(frame)
        val n = dec.decode(null, 0, 0, pcm, 0, frame, false)
        if (n > 0) pcm.copyOf(n) else null
    } catch (e: Exception) { null }

    companion object {
        fun available() = true
    }
}

/** Opus through MediaCodec (Android's Codec2 software Opus encoder/decoder). Kept for comparison tests. */
class MediaCodecOpus(override val rate: Int = 16000, bitrate: Int = 24000) : VoiceCodec {
    override val id = AudioCodec.OPUS
    override val name = "opus"
    private val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
    private val dec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
    private val encInfo = MediaCodec.BufferInfo()
    private val decInfo = MediaCodec.BufferInfo()
    private var decPts = 0L
    private var pts = 0L
    private var decRate = rate

    init {
        val ef = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, rate, 1)
        ef.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        ef.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, rate / 50 * 2 * 4)
        enc.configure(ef, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        enc.start()
        val df = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, rate, 1)
        df.setByteBuffer("csd-0", ByteBuffer.wrap(opusHead(rate)))
        df.setByteBuffer("csd-1", le64(0))
        df.setByteBuffer("csd-2", le64(80_000_000))
        dec.configure(df, null, null, 0)
        dec.start()
    }

    override fun encode(pcm: ShortArray): List<ByteArray> {
        val inIdx = enc.dequeueInputBuffer(20_000)
        if (inIdx >= 0) {
            val b = enc.getInputBuffer(inIdx)!!
            b.clear()
            b.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(pcm)
            enc.queueInputBuffer(inIdx, 0, pcm.size * 2, pts, 0)
            pts += pcm.size * 1_000_000L / rate
        }
        val out = ArrayList<ByteArray>()
        while (true) {
            val o = enc.dequeueOutputBuffer(encInfo, 0)
            if (o < 0) break
            if (encInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && encInfo.size > 0) {
                val b = enc.getOutputBuffer(o)!!
                val bytes = ByteArray(encInfo.size)
                b.position(encInfo.offset); b.get(bytes)
                out.add(bytes)
            }
            enc.releaseOutputBuffer(o, false)
        }
        return out
    }

    override fun decode(frame: ByteArray): ShortArray? {
        val inIdx = dec.dequeueInputBuffer(20_000)
        if (inIdx >= 0) {
            dec.getInputBuffer(inIdx)!!.apply { clear(); put(frame) }
            dec.queueInputBuffer(inIdx, 0, frame.size, decPts, 0)
            decPts += 20_000
        }
        var result: ShortArray? = null
        while (true) {
            val o = dec.dequeueOutputBuffer(decInfo, 0)
            if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                decRate = dec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                continue
            }
            if (o < 0) break
            if (decInfo.size > 0) {
                val sb = dec.getOutputBuffer(o)!!.order(ByteOrder.LITTLE_ENDIAN)
                sb.position(decInfo.offset)
                val s = ShortArray(decInfo.size / 2)
                sb.asShortBuffer().get(s)
                result = if (decRate == rate) s else Resample.linear(s, decRate, rate)
            }
            dec.releaseOutputBuffer(o, false)
        }
        return result
    }

    override fun release() {
        runCatching { enc.stop(); enc.release() }
        runCatching { dec.stop(); dec.release() }
    }

    companion object MediaCodecSupport {
        fun available(): Boolean = try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val f = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, 16000, 1)
            list.findEncoderForFormat(f) != null && list.findDecoderForFormat(f.apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(opusHead(16000)))
            }) != null
        } catch (t: Throwable) {
            Log.w("SimBridge", "opus probe failed", t); false
        }

        fun opusHead(rate: Int): ByteArray {
            val b = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
            b.put("OpusHead".toByteArray()); b.put(1); b.put(1); b.putShort(0); b.putInt(rate); b.putShort(0); b.put(0)
            return b.array()
        }

        private fun le64(v: Long): ByteBuffer = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(v).also { it.flip() }
    }
}

object Resample {
    fun linear(input: ShortArray, from: Int, to: Int): ShortArray {
        if (from == to || input.isEmpty()) return input
        val n = (input.size.toLong() * to / from).toInt()
        val out = ShortArray(n)
        val step = from.toDouble() / to
        for (i in 0 until n) {
            val p = i * step
            val j = p.toInt()
            val f = p - j
            val a = input[minOf(j, input.size - 1)]
            val b = input[minOf(j + 1, input.size - 1)]
            out[i] = (a + (b - a) * f).toInt().toShort()
        }
        return out
    }
}
