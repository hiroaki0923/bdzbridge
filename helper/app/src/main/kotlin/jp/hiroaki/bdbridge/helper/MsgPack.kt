package jp.hiroaki.bdbridge.helper

/**
 * Reads the MessagePack-shaped values the tuner puts in `internal_provider_data`: a flat sequence such as
 * `4, eventId, 0, 3, -1, [sibling service ids], [their event ids], ""`. Only the types seen there are
 * decoded; anything else ends the read, and the caller keeps the raw bytes beside the result.
 */
object MsgPack {
    fun decode(bytes: ByteArray): List<Any?> {
        val out = ArrayList<Any?>()
        var pos = 0
        while (pos < bytes.size) {
            val (value, next) = readValue(bytes, pos) ?: break
            out.add(value)
            pos = next
        }
        return out
    }

    private fun readValue(b: ByteArray, at: Int): Pair<Any?, Int>? {
        if (at >= b.size) return null
        val t = b[at].toInt() and 0xff
        return when {
            t <= 0x7f -> t to at + 1
            t >= 0xe0 -> (t - 0x100) to at + 1
            t in 0x90..0x9f -> readArray(b, at + 1, t - 0x90)
            t in 0xa0..0xbf -> readString(b, at + 1, t - 0xa0)
            t == 0xc0 -> null to at + 1
            t == 0xc2 -> false to at + 1
            t == 0xc3 -> true to at + 1
            t == 0xcc -> if (at + 1 < b.size) (b[at + 1].toInt() and 0xff) to at + 2 else null
            t == 0xcd -> if (at + 2 < b.size) (((b[at + 1].toInt() and 0xff) shl 8) or (b[at + 2].toInt() and 0xff)) to at + 3 else null
            t == 0xce -> if (at + 4 < b.size) readUInt32(b, at + 1).let { it to at + 5 } else null
            t == 0xd0 -> if (at + 1 < b.size) b[at + 1].toInt() to at + 2 else null
            t == 0xd1 -> if (at + 2 < b.size) (((b[at + 1].toInt() and 0xff) shl 8) or (b[at + 2].toInt() and 0xff)).toShort().toInt() to at + 3 else null
            t == 0xd2 -> if (at + 4 < b.size) readUInt32(b, at + 1).toInt() to at + 5 else null
            t == 0xd9 -> if (at + 1 < b.size) readString(b, at + 2, b[at + 1].toInt() and 0xff) else null
            t == 0xdc -> if (at + 2 < b.size) readArray(b, at + 3, ((b[at + 1].toInt() and 0xff) shl 8) or (b[at + 2].toInt() and 0xff)) else null
            else -> null
        }
    }

    private fun readUInt32(b: ByteArray, at: Int): Long =
        ((b[at].toLong() and 0xff) shl 24) or ((b[at + 1].toLong() and 0xff) shl 16) or
            ((b[at + 2].toLong() and 0xff) shl 8) or (b[at + 3].toLong() and 0xff)

    private fun readArray(b: ByteArray, at: Int, count: Int): Pair<Any?, Int>? {
        val items = ArrayList<Any?>(count)
        var pos = at
        repeat(count) {
            val (v, next) = readValue(b, pos) ?: return null
            items.add(v)
            pos = next
        }
        return items to pos
    }

    private fun readString(b: ByteArray, at: Int, length: Int): Pair<Any?, Int>? {
        if (at + length > b.size) return null
        return String(b, at, length, Charsets.UTF_8) to at + length
    }
}
