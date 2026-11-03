package jp.hiroaki.bdbridge.helper

import android.content.ContentResolver
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/** What the helper knows of one broadcasting type's copy. */
class TypeState(
    val etag: String,
    val snapshotAt: Long,
    val changedAt: Long,
    val programs: Int,
    val channels: Int,
) {
    fun toJson(): JSONObject = JSONObject().put("etag", etag).put("snapshotAt", snapshotAt).put("changedAt", changedAt)
        .put("programs", programs).put("channels", channels)

    companion object {
        fun fromJson(o: JSONObject) = TypeState(o.getString("etag"), o.getLong("snapshotAt"), o.getLong("changedAt"),
            o.getInt("programs"), o.getInt("channels"))
    }
}

/**
 * The copies the API answers from: one gzipped JSON file per broadcasting type, the channel list and
 * the logos per type, each with an ETag. A copy is rebuilt in the background after the tuner's store has
 * changed and gone quiet, and kept as one generation swapped in atomically, so a request never waits
 * for a read of the store (a full read took minutes on the X95K).
 */
class Snapshots(private val dir: File, private val resolver: ContentResolver) {
    private val stateFile = File(dir, "state.json")
    private val types = HashMap<String, TypeState>()
    private var channelsEtag: String? = null
    private val logosEtag = HashMap<String, String>()

    @Volatile var building = false; private set
    @Volatile var tunerLastWrite: Long? = null; private set
    @Volatile var lastBuildMs: Long? = null; private set
    @Volatile var lastBuildError: String? = null; private set
    private var dirtySince: Long? = null

    init {
        dir.mkdirs()
        load()
    }

    val hasAnyCopy: Boolean get() = synchronized(this) { types.isNotEmpty() }

    /** Called from the content observer: the tuner wrote something. */
    fun noteChange(now: Long = System.currentTimeMillis()) {
        synchronized(this) {
            tunerLastWrite = now
            if (dirtySince == null) dirtySince = now
        }
    }

    /** True when a rebuild is due: never built, or changed and quiet for a while, or changed long ago. */
    fun isDue(now: Long = System.currentTimeMillis()): Boolean = synchronized(this) {
        if (building) return false
        if (types.isEmpty()) return true
        val since = dirtySince ?: return false
        val last = tunerLastWrite ?: since
        return now - last >= QUIET_MS || now - since >= MAX_WAIT_MS
    }

    fun rebuild(now: Long = System.currentTimeMillis()) {
        synchronized(this) {
            if (building) return
            building = true
        }
        val started = System.currentTimeMillis()
        try {
            val channels = TvGuide.channels(resolver)
            val programs = TvGuide.programs(resolver, channels)
            val present = channels.map { it.bt }.toSet()
            val newTypes = HashMap<String, TypeState>()
            for (bt in TvGuide.TYPES) {
                if (bt !in present) { File(dir, "guide-$bt.json.gz").delete(); File(dir, "logos-$bt.json").delete(); continue }
                val rows = programs[bt] ?: JSONArray()
                val body = JSONObject().put("bt", bt).put("programs", rows).toString().toByteArray()
                val etag = etagOf(body)
                val previous = synchronized(this) { types[bt] }
                writeGzip(File(dir, "guide-$bt.json.gz"), body)
                newTypes[bt] = TypeState(etag, now, if (previous?.etag == etag) previous.changedAt else now,
                    rows.length(), channels.count { it.bt == bt })
                val logos = JSONArray()
                for (ch in channels.filter { it.bt == bt }) {
                    val png = TvGuide.logo(resolver, ch.id) ?: continue
                    logos.put(JSONObject().put("sid", ch.sid).put("hash", etagOf(png).trim('"'))
                        .put("png", Base64.encodeToString(png, Base64.NO_WRAP)))
                }
                val logosBody = JSONObject().put("bt", bt).put("logos", logos).toString().toByteArray()
                writeAtomic(File(dir, "logos-$bt.json"), logosBody)
                synchronized(this) { logosEtag[bt] = etagOf(logosBody) }
            }
            val programCount = HashMap<Long, Int>()
            for ((_, rows) in programs) for (i in 0 until rows.length()) {
                val sid = rows.getJSONObject(i).getInt("sid")
                programCount[sid.toLong()] = (programCount[sid.toLong()] ?: 0) + 1
            }
            val list = JSONArray()
            for (ch in channels) {
                val o = JSONObject().put("bt", ch.bt).put("sid", ch.sid).put("onid", ch.onid).put("tsid", ch.tsid)
                    .put("number", ch.number ?: JSONObject.NULL).put("name", ch.name ?: JSONObject.NULL)
                    .put("serviceType", ch.serviceType ?: JSONObject.NULL).put("browsable", ch.browsable)
                    .put("hasPrograms", (programs[ch.bt]?.let { rows -> hasSid(rows, ch.sid) } ?: false))
                if (ch.data != null) {
                    o.put("data", Base64.encodeToString(ch.data, Base64.NO_WRAP))
                    val arrays = MsgPack.decode(ch.data).filterIsInstance<List<*>>()
                    if (arrays.isNotEmpty()) o.put("siblings", JSONArray(arrays[0]))
                }
                list.put(o)
            }
            val channelsBody = JSONObject().put("channels", list).toString().toByteArray()
            writeAtomic(File(dir, "channels.json"), channelsBody)
            synchronized(this) {
                types.clear(); types.putAll(newTypes)
                channelsEtag = etagOf(channelsBody)
                dirtySince = null
                lastBuildError = null
                lastBuildMs = System.currentTimeMillis() - started
                save()
            }
        } catch (e: SecurityException) {
            synchronized(this) { lastBuildError = "noPermission" }
            Log.w(TAG, "rebuild: $e")
        } catch (e: Exception) {
            synchronized(this) { lastBuildError = e.javaClass.simpleName }
            Log.w(TAG, "rebuild: $e")
        } finally {
            synchronized(this) { building = false }
        }
    }

    private fun hasSid(rows: JSONArray, sid: Int): Boolean {
        for (i in 0 until rows.length()) if (rows.getJSONObject(i).getInt("sid") == sid) return true
        return false
    }

    /** The gzipped guide of a type with its ETag, or null when the tuner has no such type. */
    fun guide(bt: String): Pair<ByteArray, String>? {
        val state = synchronized(this) { types[bt] } ?: return null
        val file = File(dir, "guide-$bt.json.gz")
        if (!file.exists()) return null
        return file.readBytes() to state.etag
    }

    fun channels(): Pair<ByteArray, String>? {
        val etag = synchronized(this) { channelsEtag } ?: return null
        val file = File(dir, "channels.json")
        if (!file.exists()) return null
        return file.readBytes() to etag
    }

    fun logos(bt: String): Pair<ByteArray, String>? {
        val etag = synchronized(this) { logosEtag[bt] } ?: return null
        val file = File(dir, "logos-$bt.json")
        if (!file.exists()) return null
        return file.readBytes() to etag
    }

    fun typeStates(): Map<String, TypeState> = synchronized(this) { HashMap(types) }

    fun hasType(bt: String): Boolean = synchronized(this) { types.containsKey(bt) }

    fun inflate(gz: ByteArray): ByteArray = GZIPInputStream(gz.inputStream()).use { it.readBytes() }

    private fun etagOf(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return "\"" + digest.take(16).joinToString("") { "%02x".format(it) } + "\""
    }

    private fun writeGzip(file: File, body: ByteArray) {
        val out = ByteArrayOutputStream()
        GZIPOutputStream(out).use { it.write(body) }
        writeAtomic(file, out.toByteArray())
    }

    private fun writeAtomic(file: File, bytes: ByteArray) {
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file)) throw java.io.IOException("rename ${tmp.name}")
    }

    private fun load() {
        if (!stateFile.exists()) return
        try {
            val o = JSONObject(stateFile.readText())
            val t = o.getJSONObject("types")
            for (bt in t.keys()) types[bt] = TypeState.fromJson(t.getJSONObject(bt))
            channelsEtag = o.optString("channelsEtag").ifEmpty { null }
            val l = o.optJSONObject("logosEtag") ?: JSONObject()
            for (bt in l.keys()) logosEtag[bt] = l.getString(bt)
            tunerLastWrite = if (o.isNull("tunerLastWrite")) null else o.getLong("tunerLastWrite")
        } catch (e: Exception) {
            Log.w(TAG, "state: $e")
            types.clear()
        }
    }

    private fun save() {
        val t = JSONObject()
        for ((bt, s) in types) t.put(bt, s.toJson())
        val l = JSONObject()
        for ((bt, e) in logosEtag) l.put(bt, e)
        val o = JSONObject().put("types", t).put("channelsEtag", channelsEtag ?: JSONObject.NULL).put("logosEtag", l)
            .put("tunerLastWrite", tunerLastWrite ?: JSONObject.NULL)
        writeAtomic(stateFile, o.toString().toByteArray())
    }

    companion object {
        private const val TAG = "HelperSnapshots"
        const val QUIET_MS = 10 * 60 * 1000L
        const val MAX_WAIT_MS = 60 * 60 * 1000L
    }
}
