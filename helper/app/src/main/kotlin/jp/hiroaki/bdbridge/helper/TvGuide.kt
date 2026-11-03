package jp.hiroaki.bdbridge.helper

import android.content.ContentResolver
import android.net.Uri
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/** One of the tuner's channels, as the TV's guide store has it. Nothing is normalised. */
class Channel(
    val id: Long,
    val bt: String,
    val sid: Int,
    val onid: Int,
    val tsid: Int,
    val number: String?,
    val name: String?,
    val serviceType: String?,
    val browsable: Boolean,
    val data: ByteArray?,
)

/**
 * Reads the Sony tuner's rows from Android's TV guide store (`content://android.media.tv`).
 * The store refuses a WHERE clause from a caller with only READ_TV_LISTINGS, so everything is read and
 * narrowed here. Only channels, programmes and logos are read; never what was watched or recommended.
 */
object TvGuide {
    const val TUNER = "com.sony.dtv.tvinput.tuner"
    val TYPES = listOf("td", "bs", "cs", "bs4k", "cs4k")

    private val CHANNELS = Uri.parse("content://android.media.tv/channel")
    private val PROGRAMS = Uri.parse("content://android.media.tv/program")

    /** The broadcasting type a tuner input writes, from the input's service name. */
    fun typeOf(inputId: String?): String? = when {
        inputId == null -> null
        inputId.contains("JpTerrTuner") -> "td"
        inputId.contains("JpShvBsTuner") -> "bs4k"
        inputId.contains("JpShvCsTuner") -> "cs4k"
        inputId.contains("JpBsTuner") -> "bs"
        inputId.contains("JpCsTuner") -> "cs"
        else -> null
    }

    fun channels(cr: ContentResolver): List<Channel> {
        val out = ArrayList<Channel>()
        val projection = arrayOf("_id", "package_name", "input_id", "display_number", "display_name",
            "original_network_id", "transport_stream_id", "service_id", "service_type", "browsable", "internal_provider_data")
        cr.query(CHANNELS, projection, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) != TUNER) continue
                val bt = typeOf(c.getString(2)) ?: continue
                out.add(Channel(
                    id = c.getLong(0), bt = bt,
                    sid = c.getInt(7), onid = c.getInt(5), tsid = c.getInt(6),
                    number = c.getString(3), name = c.getString(4), serviceType = c.getString(8),
                    browsable = c.getInt(9) != 0,
                    data = if (c.isNull(10)) null else c.getBlob(10),
                ))
            }
        }
        return out
    }

    /** Every programme of the given channels, grouped by broadcasting type, as rows the API serves. */
    fun programs(cr: ContentResolver, channels: List<Channel>): Map<String, JSONArray> {
        val byId = channels.associateBy { it.id }
        val out = HashMap<String, JSONArray>()
        val projection = arrayOf("channel_id", "title", "start_time_utc_millis", "end_time_utc_millis",
            "short_description", "long_description", "broadcast_genre", "canonical_genre", "content_rating",
            "video_width", "video_height", "internal_provider_flag1", "internal_provider_flag2",
            "internal_provider_flag3", "internal_provider_flag4", "internal_provider_data", "recording_prohibited")
        cr.query(PROGRAMS, projection, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val channel = byId[c.getLong(0)] ?: continue
                val row = JSONObject()
                row.put("sid", channel.sid)
                if (!c.isNull(13)) row.put("eid", c.getLong(13))
                row.put("startMs", c.getLong(2))
                row.put("endMs", c.getLong(3))
                row.put("title", c.getString(1) ?: JSONObject.NULL)
                val short = c.getString(4)
                val long = c.getString(5)
                row.put("short", short ?: JSONObject.NULL)
                if (long != null) {
                    if (short != null && short.isNotEmpty() && long.startsWith(short + "\n\n")) {
                        row.put("longTail", long.substring(short.length + 2))
                    } else {
                        row.put("long", long)
                    }
                }
                row.put("genre", c.getString(6) ?: JSONObject.NULL)
                row.put("canonicalGenre", c.getString(7) ?: JSONObject.NULL)
                row.put("rating", c.getString(8) ?: JSONObject.NULL)
                if (!c.isNull(9)) row.put("videoWidth", c.getInt(9))
                if (!c.isNull(10)) row.put("videoHeight", c.getInt(10))
                if (!c.isNull(11)) row.put("flag1", c.getLong(11))
                if (!c.isNull(12)) row.put("flag2", c.getLong(12))
                if (!c.isNull(14)) row.put("flag4", c.getLong(14))
                if (!c.isNull(16)) row.put("recordingProhibited", c.getInt(16))
                if (!c.isNull(15)) {
                    val blob = c.getBlob(15)
                    row.put("data", Base64.encodeToString(blob, Base64.NO_WRAP))
                    val arrays = MsgPack.decode(blob).filterIsInstance<List<*>>()
                    if (arrays.isNotEmpty()) row.put("siblings", JSONArray(arrays[0]))
                    if (arrays.size >= 2) row.put("siblingEids", JSONArray(arrays[1]))
                }
                out.getOrPut(channel.bt) { JSONArray() }.put(row)
            }
        }
        return out
    }

    fun logo(cr: ContentResolver, channelId: Long): ByteArray? = try {
        cr.openInputStream(Uri.parse("content://android.media.tv/channel/$channelId/logo"))?.use { it.readBytes() }
    } catch (e: Exception) {
        null
    }
}
