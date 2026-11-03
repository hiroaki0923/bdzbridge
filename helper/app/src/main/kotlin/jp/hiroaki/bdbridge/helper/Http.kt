package jp.hiroaki.bdbridge.helper

import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.zip.GZIPOutputStream
import kotlin.concurrent.thread

/** One parsed request. Headers are keyed in lower case. */
class Request(val method: String, val path: String, val headers: Map<String, String>, val body: ByteArray) {
    fun header(name: String): String? = headers[name.lowercase()]
    fun accepts(encoding: String): Boolean =
        header("accept-encoding")?.split(',')?.any { it.trim().substringBefore(';') == encoding } == true
}

/** One response. `encoding` is set when `body` is already compressed and must be sent as is. */
class Response(
    val status: Int,
    val body: ByteArray = ByteArray(0),
    val type: String = "application/json; charset=utf-8",
    val headers: Map<String, String> = emptyMap(),
    val encoding: String? = null,
) {
    companion object {
        fun json(status: Int, obj: JSONObject, headers: Map<String, String> = emptyMap()) =
            Response(status, obj.toString().toByteArray(), headers = headers)

        fun error(status: Int, code: String, headers: Map<String, String> = emptyMap()) =
            json(status, JSONObject().put("error", code), headers)

        fun notModified(etag: String) = Response(304, headers = mapOf("ETag" to etag))
    }
}

/**
 * A small HTTP/1.0-style server: one connection per request, no keep-alive, bodies up to 64 KB.
 * Responses of 1 KB and more are gzipped when the client accepts it. Enough for a LAN helper whose
 * clients are the app and curl; it is not meant to face the internet.
 */
class HttpServer(private val port: Int, private val handle: (Request) -> Response) {
    @Volatile private var socket: ServerSocket? = null

    fun start() {
        thread(isDaemon = true, name = "helper-http") {
            try {
                val server = ServerSocket(port)
                socket = server
                while (!server.isClosed) {
                    val client = try { server.accept() } catch (e: SocketException) { break }
                    thread(isDaemon = true) { serve(client) }
                }
            } catch (e: IOException) {
                Log.w(TAG, "listen on $port: $e")
            }
        }
    }

    fun stop() {
        try { socket?.close() } catch (e: IOException) { Log.w(TAG, "close: $e") }
        socket = null
    }

    val isListening: Boolean get() = socket?.isClosed == false

    private fun serve(client: Socket) {
        client.use { s ->
            s.soTimeout = 10_000
            val input = s.getInputStream()
            val request = try { parse(input) } catch (e: IOException) { null }
            val response = when {
                request == null -> Response.error(400, "badRequest")
                else -> try { handle(request) } catch (e: Throwable) {
                    Log.w(TAG, "handle ${request.path}: $e")
                    Response.error(500, "internal")
                }
            }
            try { write(s.getOutputStream(), request, response) } catch (e: IOException) { Log.w(TAG, "write: $e") }
        }
    }

    private fun parse(input: InputStream): Request? {
        val requestLine = readLine(input) ?: return null
        val parts = requestLine.split(' ')
        if (parts.size < 2) return null
        val headers = HashMap<String, String>()
        var total = requestLine.length
        while (true) {
            val line = readLine(input) ?: return null
            if (line.isEmpty()) break
            total += line.length
            if (total > 16_384) return null
            val colon = line.indexOf(':')
            if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
        }
        val length = headers["content-length"]?.toIntOrNull() ?: 0
        if (length < 0 || length > 65_536) return null
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) return null
            read += n
        }
        return Request(parts[0], parts[1].substringBefore('?'), headers, body)
    }

    private fun readLine(input: InputStream): String? {
        val buffer = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) return if (buffer.size() == 0) null else buffer.toString("ISO-8859-1")
            if (b == '\n'.code) break
            if (b != '\r'.code) buffer.write(b)
            if (buffer.size() > 8192) return null
        }
        return buffer.toString("ISO-8859-1")
    }

    private fun write(out: OutputStream, request: Request?, response: Response) {
        var body = response.body
        var encoding = response.encoding
        if (encoding == null && body.size >= 1024 && request?.accepts("gzip") == true) {
            val gz = ByteArrayOutputStream()
            GZIPOutputStream(gz).use { it.write(body) }
            body = gz.toByteArray()
            encoding = "gzip"
        }
        val head = StringBuilder("HTTP/1.1 ${response.status} ${reason(response.status)}\r\n")
        head.append("Content-Type: ${response.type}\r\n")
        head.append("Content-Length: ${body.size}\r\n")
        head.append("Cache-Control: no-cache\r\n")
        head.append("Connection: close\r\n")
        if (encoding != null) head.append("Content-Encoding: $encoding\r\nVary: Accept-Encoding\r\n")
        for ((k, v) in response.headers) head.append("$k: $v\r\n")
        head.append("\r\n")
        out.write(head.toString().toByteArray(Charsets.ISO_8859_1))
        if (request?.method != "HEAD") out.write(body)
        out.flush()
    }

    private fun reason(status: Int) = when (status) {
        200 -> "OK"; 304 -> "Not Modified"; 400 -> "Bad Request"; 401 -> "Unauthorized"; 403 -> "Forbidden"
        404 -> "Not Found"; 405 -> "Method Not Allowed"; 429 -> "Too Many Requests"; 500 -> "Internal Server Error"
        503 -> "Service Unavailable"; else -> "Status"
    }

    companion object {
        private const val TAG = "HelperHttp"
    }
}
