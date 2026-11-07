package jp.hiroaki.bdbridge

import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.ExecutionException
import jp.hiroaki.bdbridge.bridge.AndroidBridge
import kotlinx.coroutines.future.await
import org.swift.swiftkit.core.SwiftArena

/**
 * The Swift side (core/Sources/AndroidBridge) as suspending calls. What Swift hands back comes on Swift's own threads;
 * a coroutine that awaits it goes on where it was started, the main thread for the screens. A failure comes as the
 * words the iOS app says it in.
 */
object Bridge {
    private val arena: SwiftArena = SwiftArena.ofAuto()

    val demoHost: String get() = AndroidBridge.demoHost()

    suspend fun describe(host: String): Recorder =
        call { AndroidBridge.describeRecorder(host, arena) }.let { Recorder(it.host, it.name, it.model) }

    suspend fun reservations(host: String): List<ReservationItem> =
        call { AndroidBridge.reservations(host, arena) }.map {
            ReservationItem(it.id, it.title, it.date, it.span, it.details, it.isRecording, it.isConflict)
        }

    suspend fun recordings(host: String): List<RecordingItem> =
        call { AndroidBridge.recordings(host, arena) }.map {
            RecordingItem(it.id, it.title, it.date, it.details, it.isNew, it.isProtected, it.isRecording)
        }

    suspend fun search(): List<Found> =
        call { AndroidBridge.searchDevices(arena) }.map { Found(it.host, it.kind == "recorder", it.name) }

    private suspend fun <T> call(start: () -> CompletableFuture<T>): T =
        try {
            start().await()
        } catch (error: CompletionException) {
            throw BridgeFailure(error.cause?.message ?: error.message ?: "")
        } catch (error: ExecutionException) {
            throw BridgeFailure(error.cause?.message ?: error.message ?: "")
        }
}

/** What went wrong, in the iOS app's words. */
class BridgeFailure(said: String) : Exception(said)

data class Recorder(val host: String, val name: String, val model: String)

data class Found(val host: String, val isRecorder: Boolean, val name: String)

data class ReservationItem(
    val id: String, val title: String, val date: String, val span: String, val details: String,
    val recording: Boolean, val conflict: Boolean,
)

data class RecordingItem(
    val id: String, val title: String, val date: String, val details: String,
    val isNew: Boolean, val protected: Boolean, val recording: Boolean,
)
