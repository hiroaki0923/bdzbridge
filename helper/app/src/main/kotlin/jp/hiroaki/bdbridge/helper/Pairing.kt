package jp.hiroaki.bdbridge.helper

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom

/** A phone that was let in with a code shown on the TV. Only a hash of its token is kept. */
class Device(val id: String, val label: String, val tokenHash: String, val createdAt: Long, var lastUsedAt: Long?) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("label", label).put("createdAt", createdAt).put("lastUsedAt", lastUsedAt ?: JSONObject.NULL)
}

/** What redeeming a code came to. */
sealed class Pairing {
    class Granted(val token: String, val device: Device) : Pairing()
    object NoCode : Pairing()
    object BadCode : Pairing()
    object Locked : Pairing()
}

/**
 * Registration by a 6-digit code: the TV screen shows one for five minutes; a phone posts it once and
 * gets a token. Five wrong codes end the code and lock registration for ten minutes. Tokens are random,
 * stored hashed, and revoked per device on the TV screen. Nothing else lets a client in.
 */
class Devices(private val file: File) {
    private val random = SecureRandom()
    private val devices = ArrayList<Device>()
    private var code: String? = null
    private var codeExpiresAt = 0L
    private var failures = 0
    private var lockedUntil = 0L
    private var registered: Device? = null

    init { load() }

    @Synchronized fun list(): List<Device> = devices.map { it }

    @Synchronized fun showCode(now: Long = System.currentTimeMillis()): String? {
        if (now < lockedUntil) return null
        if (code == null || now >= codeExpiresAt) {
            code = String.format("%06d", random.nextInt(1_000_000))
            codeExpiresAt = now + CODE_LIFETIME_MS
        }
        return code
    }

    @Synchronized fun codeRemainingMs(now: Long = System.currentTimeMillis()): Long =
        if (code == null) 0 else maxOf(0, codeExpiresAt - now)

    @Synchronized fun lockedRemainingMs(now: Long = System.currentTimeMillis()): Long = maxOf(0, lockedUntil - now)

    @Synchronized fun hideCode() { code = null }

    @Synchronized fun redeem(given: String, label: String, now: Long = System.currentTimeMillis()): Pairing {
        if (now < lockedUntil) return Pairing.Locked
        val current = code
        if (current == null || now >= codeExpiresAt) { code = null; return Pairing.NoCode }
        if (!MessageDigest.isEqual(current.toByteArray(), given.toByteArray())) {
            failures++
            if (failures >= MAX_FAILURES) {
                failures = 0
                code = null
                lockedUntil = now + LOCK_MS
                return Pairing.Locked
            }
            return Pairing.BadCode
        }
        code = null
        failures = 0
        val bytes = ByteArray(32).also { random.nextBytes(it) }
        val token = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        val device = Device(newId(), label.take(64).ifBlank { "iPhone" }, hash(token), now, null)
        devices.add(device)
        registered = device
        save()
        return Pairing.Granted(token, device)
    }

    /** The phone let in since the screen last asked, so the screen can stop showing a code. */
    @Synchronized fun takeRegistered(): Device? = registered.also { registered = null }

    @Synchronized fun authenticate(token: String, now: Long = System.currentTimeMillis()): Device? {
        val h = hash(token)
        val device = devices.firstOrNull { MessageDigest.isEqual(it.tokenHash.toByteArray(), h.toByteArray()) } ?: return null
        if (device.lastUsedAt == null || now - device.lastUsedAt!! > 60_000) {
            device.lastUsedAt = now
            save()
        }
        return device
    }

    @Synchronized fun revoke(id: String): Boolean {
        val removed = devices.removeAll { it.id == id }
        if (removed) save()
        return removed
    }

    private fun newId(): String {
        val bytes = ByteArray(8).also { random.nextBytes(it) }
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun hash(token: String): String =
        MessageDigest.getInstance("SHA-256").digest(token.toByteArray()).joinToString("") { "%02x".format(it) }

    private fun load() {
        if (!file.exists()) return
        try {
            val arr = JSONObject(file.readText()).optJSONArray("devices") ?: JSONArray()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                devices.add(Device(o.getString("id"), o.getString("label"), o.getString("tokenHash"), o.getLong("createdAt"),
                    if (o.isNull("lastUsedAt")) null else o.getLong("lastUsedAt")))
            }
        } catch (e: Exception) {
            devices.clear()
        }
    }

    private fun save() {
        val arr = JSONArray()
        for (d in devices) arr.put(d.toJson().put("tokenHash", d.tokenHash))
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(JSONObject().put("devices", arr).toString())
        tmp.renameTo(file)
    }

    companion object {
        const val CODE_LIFETIME_MS = 5 * 60 * 1000L
        const val LOCK_MS = 10 * 60 * 1000L
        const val MAX_FAILURES = 5
    }
}
