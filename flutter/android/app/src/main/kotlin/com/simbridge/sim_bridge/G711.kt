package com.simbridge.sim_bridge

/** G.711 µ-law, bit-exact with the iOS implementation and the Dart port (`lib/src/protocol/audio.dart`). */
object G711 {
    fun encode(sample: Short): Byte {
        var s = sample.toInt()
        val sign = if (s < 0) 0x80 else 0
        if (s < 0) s = -s
        if (s > 32635) s = 32635
        s += 0x84
        var exp = 7
        var mask = 0x4000
        while (exp > 0 && (s and mask) == 0) { exp--; mask = mask shr 1 }
        val mant = (s shr (exp + 3)) and 0x0f
        return (sign or (exp shl 4) or mant).inv().toByte()
    }

    fun decode(b: Byte): Short {
        val u = b.toInt().inv() and 0xff
        val sign = u and 0x80
        val exp = (u shr 4) and 7
        val mant = u and 0x0f
        val s = (((mant shl 3) + 0x84) shl exp) - 0x84
        return (if (sign != 0) -s else s).toShort()
    }

    fun encode(pcm: ShortArray) = ByteArray(pcm.size) { encode(pcm[it]) }
    fun decode(b: ByteArray) = ShortArray(b.size) { decode(b[it]) }
}

/** Audio-channel codec ids. Must match the Dart side (`lib/src/protocol/audio.dart`) and iOS. */
object AudioCodec {
    const val OPUS = 1
    const val PCMU = 2
}
