package jp.hiroaki.bdbridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.concurrent.CompletableFuture
import jp.hiroaki.bdbridge.bridge.AndroidBridge
import jp.hiroaki.bdbridge.bridge.DevicesWindow
import jp.hiroaki.bdbridge.bridge.GuideWindow
import jp.hiroaki.bdbridge.bridge.RecBridgeApp
import jp.hiroaki.bdbridge.bridge.RecordingsWindow
import jp.hiroaki.bdbridge.bridge.ReservationsWindow
import jp.hiroaki.bdbridge.bridge.ScreenListener
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.swift.swiftkit.core.SwiftArena

/** Where what Swift hands over is kept until nothing here holds it. */
private val arena: SwiftArena = SwiftArena.ofAuto()

/**
 * The app's model (core/Sources/AndroidBridge), one for the process as the iOS app has one, and what its screens
 * show. Each window says when what it shows has changed; it is read again then, turned into the values below off the
 * main thread, and put where Compose reads it. What the reader does goes to the window as a suspending call.
 */
object RecBridge {
    private val scope = MainScope()
    private val opened = CompletableDeferred<Windows>()
    private var opening = false

    class Windows(
        val app: RecBridgeApp, val devices: DevicesWindow, val guide: GuideWindow,
        val reservations: ReservationsWindow, val recordings: RecordingsWindow,
    )

    private val _devices = MutableStateFlow<Devices?>(null)
    private val _guide = MutableStateFlow<Guide?>(null)
    private val _reservations = MutableStateFlow<Reservations?>(null)
    private val _recordings = MutableStateFlow<Recordings?>(null)
    val devices: StateFlow<Devices?> = _devices
    val guide: StateFlow<Guide?> = _guide
    val reservations: StateFlow<Reservations?> = _reservations
    val recordings: StateFlow<Recordings?> = _recordings

    /** Whether the model has been asked to open in this process. */
    val isOpen: Boolean get() = opening

    /** Opens the model the first time it is asked, with the app's folder, and starts it. */
    fun open(context: Context) {
        if (opening) return
        opening = true
        val files = context.filesDir.absolutePath
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val version = "${info.versionName} (${info.longVersionCode})"
        scope.launch {
            val app = call { RecBridgeApp.open(files, version, arena) }
            val windows = Windows(app, app.devices(arena), app.guide(arena), app.reservations(arena), app.recordings(arena))
            watch({ windows.devices.observe(it) }, { Devices(call { windows.devices.read(arena) }) }, _devices)
            watch({ windows.guide.observe(it) }, { Guide(call { windows.guide.read(arena) }) }, _guide)
            watch({ windows.reservations.observe(it) }, { Reservations(call { windows.reservations.read(arena) }) }, _reservations)
            watch({ windows.recordings.observe(it) }, { Recordings(call { windows.recordings.read(arena) }) }, _recordings)
            opened.complete(windows)
            call<Void> { app.start() }
        }
    }

    /** The windows, once the model is open. */
    suspend fun windows(): Windows = opened.await()

    /** Does what the reader asked of a window, keeping Swift's main queue running until it is done. */
    suspend fun act(operation: (Windows) -> CompletableFuture<*>) {
        val windows = windows()
        call<Any?> { operation(windows).thenApply { it } }
    }

    /** Asks a window for what it answers, the same way. */
    suspend fun <T> ask(operation: (Windows) -> CompletableFuture<T>): T {
        val windows = windows()
        return call { operation(windows) }
    }

    /** A typed address as the iOS field says it. */
    suspend fun typed(text: String): Typed = windows().devices.typed(text, arena).let {
        Typed(it.host, it.isUsable, it.note, it.isWarning)
    }

    /**
     * The app has come into sight or gone out of it. The model is told in the order it happened, one change after the
     * other, as the iOS app tells it its scene's: told together, a quick leave and return could reach it the other
     * way round, and leave it thinking the app away while it is on screen.
     */
    fun onScreen(shown: Boolean) {
        MainQueue.onScreen(shown)
        sightings.trySend(shown)
    }

    private val sightings = Channel<Boolean>(Channel.UNLIMITED).also { changes ->
        scope.launch {
            for (shown in changes) {
                val app = windows().app
                call<Void> { app.activeChanged(shown) }
                if (shown) call<Void> { app.returnedToForeground() } else call<Void> { app.wentToBackground() }
            }
        }
    }

    /**
     * Reads what a window shows each time it says it changed, one read at a time and only the latest: told twice while
     * a read is out, it reads once more after it.
     */
    private fun <T> watch(observe: (ScreenListener) -> Unit, read: suspend () -> T, into: MutableStateFlow<T?>) {
        val changes = Channel<Unit>(Channel.CONFLATED)
        observe(object : ScreenListener {
            override fun changed() {
                changes.trySend(Unit)
            }
        })
        scope.launch {
            for (change in changes) into.value = withContext(Dispatchers.Default) { read() }
        }
    }

    /**
     * A call to Swift, counted for as long as Swift is at it: a screen that stops waiting, closed or keyed anew, does
     * not stop the operation, which goes on in the model as it does on iOS, and the main queue is run until it is done.
     */
    private suspend fun <T> call(start: () -> CompletableFuture<T>): T {
        MainQueue.calling(true)
        try {
            val answer = start()
            return withContext(NonCancellable) { answer.await() }
        } finally {
            MainQueue.calling(false)
        }
    }
}

/**
 * Swift's main queue, which nothing else runs on Android, run from the main thread: much of RecorderKit, and the
 * app's model, are on Swift's main actor (core/Sources/AndroidBridge/MainQueue.swift). It runs while the app is on
 * screen, and while a call to Swift is out, so that one made as the app goes out of sight -- the model told that it
 * has -- is answered. Each run takes what has come since the last and returns at once; one comes every frame or so.
 */
private object MainQueue {
    private val mainThread = Handler(Looper.getMainLooper())
    private var shown = false
    private var calls = 0
    private var running = false
    private val runner = object : Runnable {
        override fun run() {
            AndroidBridge.runWhatWaitsOnTheMainQueue()
            if (shown || calls > 0) mainThread.postDelayed(this, 16) else running = false
        }
    }

    fun onScreen(on: Boolean) = mainThread.post {
        shown = on
        keepRunning()
    }

    fun calling(started: Boolean) = mainThread.post {
        calls += if (started) 1 else -1
        keepRunning()
    }

    private fun keepRunning() {
        if (running || !(shown || calls > 0)) return
        running = true
        mainThread.post(runner)
    }
}

data class NoRecorder(val kind: String, val title: String, val detail: String)

data class Choice(val code: String, val label: String)

data class Station(val serviceID: Long, val name: String)

data class Devices(
    val welcomes: Boolean, val searching: Boolean, val searched: Long, val toSearch: Long,
    val outcome: String, val outcomeFailed: Boolean, val outcomeNote: String, val causes: List<String>,
    val busy: String, val problem: String, val recorders: List<FoundRecorder>,
    val canChoose: Boolean, val demo: Boolean, val chosenAnswered: Boolean,
)

data class FoundRecorder(val host: String, val name: String, val details: String, val inUse: Boolean)

data class Typed(val host: String, val usable: Boolean, val note: String, val warning: Boolean)

data class Guide(
    val shows: String, val noRecorder: NoRecorder, val title: String, val detail: String, val offers: String,
    val heading: String, val broadcastings: List<Choice>, val broadcasting: String, val stations: List<Station>,
    val station: Long, val days: List<String>, val day: Int, val programmes: List<Programme>, val nowRequests: Long,
    val canRefresh: Boolean, val demo: Boolean,
)

data class Programme(
    val id: String, val time: String, val length: String, val title: String, val station: String, val mark: String,
    val markIsRed: Boolean, val genre: String, val summary: String, val starts: Long, val ends: Long,
)

data class ProgrammeSheet(
    val title: String, val station: String, val starts: String, val length: String, val genre: String,
    val summary: String, val extended: String,
)

data class Reservations(
    val hasNoRecorder: Boolean, val noRecorder: NoRecorder, val isEmpty: Boolean, val emptyTitle: String,
    val emptyDetail: String, val subtitle: String, val waiting: List<Waiting>, val sections: List<Section>,
    val line: String, val lineIsAProblem: Boolean, val loadKey: String,
)

data class Section(val title: String, val rows: List<ReservationItem>)

data class ReservationItem(
    val id: String, val time: String, val length: String, val recording: Boolean, val conflict: Boolean,
    val byTheRecorder: Boolean, val title: String, val details: String,
)

data class Waiting(val id: String, val title: String, val details: String, val problem: String)

data class Recordings(
    val hasNoRecorder: Boolean, val noRecorder: NoRecorder, val isLoading: Boolean, val loadingTitle: String,
    val loadingDetail: String, val emptyTitle: String, val emptyDetail: String, val heading: String,
    val subtitle: String, val rows: List<RecordingItem>, val line: String, val lineIsAProblem: Boolean,
    val loadKey: String, val tvKey: String, val outdatedKey: String,
)

data class RecordingItem(
    val id: String, val title: String, val recording: Boolean, val protected: Boolean, val details: String,
    val watched: String, val unwatched: Boolean, val genre: String,
)

private fun NoRecorder(said: jp.hiroaki.bdbridge.bridge.NoRecorder) =
    said.getSaid(arena).let { NoRecorder(said.kind, it.title, it.detail) }

private fun Devices(it: jp.hiroaki.bdbridge.bridge.DevicesScreen) = Devices(
    it.isWelcomes, it.isSearching, it.searched, it.toSearch, it.outcome, it.isOutcomeFailed, it.outcomeNote,
    it.causes.toList(), it.busy, it.problem,
    it.getRecorders(arena).map { found -> FoundRecorder(found.host, found.name, found.details, found.isInUse) },
    it.isCanChoose, it.isDemo, it.isChosenAnswered,
)

private fun Guide(it: jp.hiroaki.bdbridge.bridge.GuideScreen) = it.getSaid(arena).let { said ->
    Guide(
        it.shows, NoRecorder(it.getNoRecorder(arena)), said.title, said.detail, it.offers, it.heading,
        it.getBroadcastings(arena).map { choice -> Choice(choice.code, choice.label) }, it.broadcasting,
        it.getStations(arena).map { station -> Station(station.serviceID, station.name) }, it.station,
        it.days.toList(), it.day.toInt(),
        it.getProgrammes(arena).map { row ->
            Programme(row.id, row.time, row.length, row.title, row.station, row.mark, row.isMarkIsRed, row.genre,
                      row.summary, row.starts, row.ends)
        },
        it.nowRequests, it.isCanRefresh, it.isDemo,
    )
}

private fun Reservations(it: jp.hiroaki.bdbridge.bridge.ReservationsScreen) = it.getEmpty(arena).let { empty ->
    Reservations(
        it.isHasNoRecorder, NoRecorder(it.getNoRecorder(arena)), it.isEmpty, empty.title, empty.detail, it.subtitle,
        it.getWaiting(arena).map { row -> Waiting(row.id, row.title, row.details, row.problem) },
        it.getSections(arena).map { section ->
            Section(section.title, section.getRows(arena).map { row ->
                ReservationItem(row.id, row.time, row.length, row.isRecording, row.isConflict, row.isByTheRecorder,
                                row.title, row.details)
            })
        },
        it.line, it.isLineIsAProblem, it.loadKey,
    )
}

private fun Recordings(it: jp.hiroaki.bdbridge.bridge.RecordingsScreen): Recordings {
    val loading = it.getLoading(arena)
    val empty = it.getEmpty(arena)
    return Recordings(
        it.isHasNoRecorder, NoRecorder(it.getNoRecorder(arena)), it.isLoading, loading.title, loading.detail,
        empty.title, empty.detail, it.heading, it.subtitle,
        it.getRows(arena).map { row ->
            RecordingItem(row.id, row.title, row.isRecording, row.isProtected, row.details, row.watched,
                          row.isUnwatched, row.genre)
        },
        it.line, it.isLineIsAProblem, it.loadKey, it.tvKey, it.outdatedKey,
    )
}

/** The sheet of a programme on the day shown, read when it is opened. */
suspend fun programmeSheet(id: String): ProgrammeSheet? =
    RecBridge.ask { it.guide.programme(id, arena) }.orElse(null)?.let {
        ProgrammeSheet(it.title, it.station, it.starts, it.length, it.genre, it.summary, it.extended)
    }
