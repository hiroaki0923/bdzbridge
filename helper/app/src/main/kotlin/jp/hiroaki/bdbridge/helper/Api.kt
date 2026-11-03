package jp.hiroaki.bdbridge.helper

import android.content.Context
import android.os.PowerManager
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.util.TimeZone

/**
 * The helper's HTTP API. `/ping` and `POST /v1/pair` need no token; everything else needs
 * `Authorization: Bearer <token>` from a registration made on the TV screen.
 */
class Api(private val context: Context) {
    private val snapshots get() = Helper.snapshots(context)
    private val devices get() = Helper.devices(context)

    fun handle(req: Request): Response {
        if (req.method != "GET" && req.method != "HEAD" && req.method != "POST") return Response.error(405, "methodNotAllowed")
        return when {
            req.path == "/ping" -> ping()
            req.path == "/v1/pair" -> if (req.method == "POST") pair(req) else Response.error(405, "methodNotAllowed")
            req.path.startsWith("/v1/") -> {
                authenticate(req) ?: return Response.error(401, "unauthorized")
                when {
                    req.path == "/v1/info" -> info()
                    req.path == "/v1/channels" -> cached(req, snapshots.channels())
                    req.path.startsWith("/v1/guide/") -> guide(req, req.path.removePrefix("/v1/guide/"))
                    req.path.startsWith("/v1/logos/") -> logos(req, req.path.removePrefix("/v1/logos/"))
                    else -> Response.error(404, "notFound")
                }
            }
            else -> Response.error(404, "notFound")
        }
    }

    private fun ping(): Response = Response.json(200, JSONObject()
        .put("app", "recbridge-helper").put("api", JSONArray().put(Helper.API_VERSION)).put("version", BuildConfig.VERSION_NAME))

    private fun pair(req: Request): Response {
        val body = try { JSONObject(String(req.body, Charsets.UTF_8)) } catch (e: Exception) { return Response.error(400, "badRequest") }
        val code = body.optString("code")
        val label = body.optString("label")
        if (code.length != 6 || !code.all { it.isDigit() }) return Response.error(400, "badRequest")
        return when (val result = devices.redeem(code, label)) {
            is Pairing.Granted -> Response.json(200, JSONObject().put("token", result.token).put("deviceId", result.device.id)
                .put("api", JSONArray().put(Helper.API_VERSION)).put("version", BuildConfig.VERSION_NAME))
            Pairing.NoCode -> Response.error(403, "noCode")
            Pairing.BadCode -> Response.error(403, "badCode")
            Pairing.Locked -> Response.error(429, "locked", mapOf("Retry-After" to (Devices.LOCK_MS / 1000).toString()))
        }
    }

    private fun authenticate(req: Request): Device? {
        val value = req.header("authorization") ?: return null
        if (!value.startsWith("Bearer ", ignoreCase = true)) return null
        return devices.authenticate(value.substring(7).trim())
    }

    private fun info(): Response {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val types = JSONObject()
        for ((bt, s) in snapshots.typeStates()) types.put(bt, s.toJson())
        val o = JSONObject()
            .put("helperVersion", BuildConfig.VERSION_NAME)
            .put("api", JSONArray().put(Helper.API_VERSION))
            .put("features", JSONArray())
            .put("listingsPermission", Helper.hasListingsPermission(context))
            .put("tunerInstalled", Helper.tunerInstalled(context))
            .put("interactive", pm.isInteractive)
            .put("now", System.currentTimeMillis())
            .put("timeZone", TimeZone.getDefault().id)
            .put("bootedAt", System.currentTimeMillis() - SystemClock.elapsedRealtime())
            .put("startedAt", Helper.startedAt ?: JSONObject.NULL)
            .put("building", snapshots.building)
            .put("lastBuildMs", snapshots.lastBuildMs ?: JSONObject.NULL)
            .put("lastBuildError", snapshots.lastBuildError ?: JSONObject.NULL)
            .put("tunerLastWrite", snapshots.tunerLastWrite ?: JSONObject.NULL)
            .put("freeSpace", context.filesDir.usableSpace)
            .put("types", types)
        return Response.json(200, o)
    }

    private fun guide(req: Request, bt: String): Response {
        if (bt !in TvGuide.TYPES) return Response.error(404, "noSuchType")
        if (!snapshots.hasAnyCopy) return notReady()
        val (gz, etag) = snapshots.guide(bt) ?: return Response.error(404, "noSuchType")
        if (req.header("if-none-match") == etag) return Response.notModified(etag)
        return if (req.accepts("gzip")) Response(200, gz, headers = mapOf("ETag" to etag), encoding = "gzip")
        else Response(200, snapshots.inflate(gz), headers = mapOf("ETag" to etag))
    }

    private fun logos(req: Request, bt: String): Response {
        if (bt !in TvGuide.TYPES) return Response.error(404, "noSuchType")
        if (!snapshots.hasAnyCopy) return notReady()
        return cached(req, snapshots.logos(bt) ?: return Response.error(404, "noSuchType"))
    }

    private fun cached(req: Request, found: Pair<ByteArray, String>?): Response {
        if (!snapshots.hasAnyCopy) return notReady()
        val (body, etag) = found ?: return Response.error(404, "notFound")
        if (req.header("if-none-match") == etag) return Response.notModified(etag)
        return Response(200, body, headers = mapOf("ETag" to etag))
    }

    private fun notReady(): Response {
        val reason = when {
            !Helper.hasListingsPermission(context) -> "noPermission"
            !Helper.tunerInstalled(context) -> "noTuner"
            else -> "building"
        }
        return Response.error(503, reason, mapOf("Retry-After" to "60"))
    }
}
