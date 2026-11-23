package com.simbridge.sim_bridge

/** The last 9 digits of a number (Persian/Arabic digits included), the same key the Dart side uses. */
fun numberKey(value: String): String {
    val digits = StringBuilder()
    for (ch in value) {
        val d = when (ch) {
            in '\u06F0'..'\u06F9' -> '0' + (ch - '\u06F0')
            in '\u0660'..'\u0669' -> '0' + (ch - '\u0660')
            else -> ch
        }
        if (d.isDigit()) digits.append(d)
    }
    val s = digits.toString()
    return if (s.length <= 9) s else s.substring(s.length - 9)
}
