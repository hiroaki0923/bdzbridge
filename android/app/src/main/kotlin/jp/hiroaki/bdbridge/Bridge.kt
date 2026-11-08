package jp.hiroaki.bdbridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.concurrent.CompletableFuture
import jp.hiroaki.bdbridge.bridge.AndroidBridge
import jp.hiroaki.bdbridge.bridge.DevicesWindow
import jp.hiroaki.bdbridge.bridge.GuideWindow
import jp.hiroaki.bdbridge.bridge.ProgrammeSheetWindow
import jp.hiroaki.bdbridge.bridge.RecBridgeApp
import jp.hiroaki.bdbridge.bridge.RecordingsWindow
import jp.hiroaki.bdbridge.bridge.ReservationSheetWindow
import jp.hiroaki.bdbridge.bridge.ReservationsWindow
import jp.hiroaki.bdbridge.bridge.ScreenListener
import jp.hiroaki.bdbridge.bridge.StripWindow
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
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
        val reservations: ReservationsWindow, val recordings: RecordingsWindow, val strip: StripWindow,
    )

    private val _devices = MutableStateFlow<Devices?>(null)
    private val _guide = MutableStateFlow<Guide?>(null)
    private val _reservations = MutableStateFlow<Reservations?>(null)
    private val _recordings = MutableStateFlow<Recordings?>(null)
    private val _strip = MutableStateFlow<Strip?>(null)
    val devices: StateFlow<Devices?> = _devices
    val guide: StateFlow<Guide?> = _guide
    val reservations: StateFlow<Reservations?> = _reservations
    val recordings: StateFlow<Recordings?> = _recordings
    val strip: StateFlow<Strip?> = _strip

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
            val windows = Windows(app, app.devices(arena), app.guide(arena), app.reservations(arena),
                                  app.recordings(arena), app.strip(arena))
            watch({ windows.devices.observe(it) }, { Devices(call { windows.devices.read(arena) }) }, _devices)
            watch({ windows.guide.observe(it) }, { Guide(call { windows.guide.read(arena) }) }, _guide)
            watch({ windows.reservations.observe(it) }, { Reservations(call { windows.reservations.read(arena) }) }, _reservations)
            watch({ windows.recordings.observe(it) }, { Recordings(call { windows.recordings.read(arena) }) }, _recordings)
            watch({ windows.strip.observe(it) }, { Strip(call { windows.strip.read(arena) }) }, _strip)
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
     * a read is out, it reads once more after it. The job handed back ends the reading, for a sheet that closes.
     */
    private fun <T> watch(observe: (ScreenListener) -> Unit, read: suspend () -> T, into: MutableStateFlow<T?>): Job {
        val changes = Channel<Unit>(Channel.CONFLATED)
        observe(object : ScreenListener {
            override fun changed() {
                changes.trySend(Unit)
            }
        })
        return scope.launch {
            for (change in changes) into.value = withContext(Dispatchers.Default) { read() }
        }
    }

    /** The sheet of a programme on the day shown, opened: nil when the day no longer has it. */
    suspend fun openProgramme(id: String): ProgrammeSheetHandle? =
        ask { it.guide.open(id, arena) }.orElse(null)?.let { ProgrammeSheetHandle(it) }

    /** The sheet of a reservation in the list, opened: nil when the list no longer has it. */
    suspend fun openReservation(id: String): ReservationSheetHandle? =
        ask { it.reservations.open(id, arena) }.orElse(null)?.let { ReservationSheetHandle(it) }

    /** A sheet's window, read as the screens' are, until the sheet closes. */
    abstract class Sheet<T>(observe: (ScreenListener) -> Unit, read: suspend () -> T) {
        private val _shown = MutableStateFlow<T?>(null)
        val shown: StateFlow<T?> = _shown
        private val reading = watch(observe, read, _shown)

        /** The sheet has closed: nothing more is read, and the window follows nothing more for it. */
        fun close() {
            reading.cancel()
            scope.launch { ended() }
        }

        protected abstract suspend fun ended()
    }

    class ProgrammeSheetHandle(private val window: ProgrammeSheetWindow) :
        Sheet<ProgrammeSheetScreen>({ window.observe(it) }, { ProgrammeSheetScreen(call { window.read(arena) }) }) {
        override suspend fun ended() = call<Void> { window.closed() }.let {}
        suspend fun chooseDevice(code: String) = call<Void> { window.chooseDevice(code) }.let {}
        suspend fun chooseDisk(code: String) = call<Void> { window.chooseDisk(code) }.let {}
        suspend fun chooseQuality(code: String) = call<Void> { window.chooseQuality(code) }.let {}
        suspend fun chooseRepeat(code: String) = call<Void> { window.chooseRepeat(code) }.let {}
        suspend fun reserve() = call<Void> { window.reserve() }.let {}
        suspend fun delete(device: String) = call<Void> { window.delete(device) }.let {}
        suspend fun sendAgain(device: String) = call<Void> { window.sendAgain(device) }.let {}
        suspend fun deleteWaiting(device: String) = call<Void> { window.deleteWaiting(device) }.let {}
        suspend fun act() = call<Void> { window.act() }.let {}
        suspend fun closeAsked() = call<Void> { window.closeAsked() }.let {}
        /** 予約を変更する: the reservation's own sheet, over this one. */
        suspend fun change(device: String): ReservationSheetHandle? =
            call { window.change(device, arena) }.orElse(null)?.let { ReservationSheetHandle(it) }
        suspend fun changeClosed() = call<Void> { window.changeClosed() }.let {}
    }

    class ReservationSheetHandle(private val window: ReservationSheetWindow) :
        Sheet<ReservationSheetScreen>({ window.observe(it) }, { ReservationSheetScreen(call { window.read(arena) }) }) {
        override suspend fun ended() = call<Void> { window.closed() }.let {}
        suspend fun chooseQuality(code: String) = call<Void> { window.chooseQuality(code) }.let {}
        suspend fun chooseRepeat(code: String) = call<Void> { window.chooseRepeat(code) }.let {}
        suspend fun chooseDisk(code: String) = call<Void> { window.chooseDisk(code) }.let {}
        suspend fun sendTheChange() = call<Void> { window.sendTheChange() }.let {}
        suspend fun delete() = call<Void> { window.delete() }.let {}
        suspend fun confirmDelete() = call<Void> { window.confirmDelete() }.let {}
        suspend fun closeAsked() = call<Void> { window.closeAsked() }.let {}
    }

    /**
     * A call to Swift, counted for as long as Swift is at it: a screen that stops waiting, closed or keyed anew, does
     * not stop the operation, which goes on in the model as it does on iOS, and the main queue is run until it is done.
     */
    internal suspend fun <T> call(start: () -> CompletableFuture<T>): T {
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

/** A station, and the logo the recorder sent for it as an image file (empty when it never had one). */
class Station(val serviceID: Long, val name: String, val logo: ByteArray)

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
    val id: String, val serviceID: Long, val time: String, val length: String, val title: String, val station: String, val mark: String,
    val markIsRed: Boolean, val genre: String, val summary: String, val starts: Long, val ends: Long,
)

data class Reservations(
    val hasNoRecorder: Boolean, val noRecorder: NoRecorder, val isEmpty: Boolean, val emptyTitle: String,
    val emptyDetail: String, val subtitle: String, val waiting: List<Waiting>, val waitingSays: String,
    val sections: List<Section>,
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
        it.getStations(arena).map { station -> Station(station.serviceID, station.name, station.logo) }, it.station,
        it.days.toList(), it.day.toInt(),
        it.getProgrammes(arena).map { row ->
            Programme(row.id, row.serviceID, row.time, row.length, row.title, row.station, row.mark, row.isMarkIsRed, row.genre,
                      row.summary, row.starts, row.ends)
        },
        it.nowRequests, it.isCanRefresh, it.isDemo,
    )
}

private fun Reservations(it: jp.hiroaki.bdbridge.bridge.ReservationsScreen) = it.getEmpty(arena).let { empty ->
    Reservations(
        it.isHasNoRecorder, NoRecorder(it.getNoRecorder(arena)), it.isEmpty, empty.title, empty.detail, it.subtitle,
        it.getWaiting(arena).map { row -> Waiting(row.id, row.title, row.details, row.problem) }, it.waitingSays,
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

/** The strip at the top of every screen (`StripWindow`): `kind` is empty when it has nothing to say. */
data class Strip(val kind: String, val text: String, val inFull: Boolean, val action: String, val actionEnabled: Boolean)

private fun Strip(it: jp.hiroaki.bdbridge.bridge.StripLine) =
    Strip(it.kind, it.text, it.isInFull, it.action, it.isActionEnabled)


/** A value with its words, as a picker offers it. */
data class Labelled(val code: String, val label: String)

/** The one question or answer up at a time on a sheet. `action` is empty where there is only the closing button. */
data class Asked(val title: String, val message: String, val action: String, val destructive: Boolean, val closing: String)

data class HeldReservation(
    val heading: String, val quality: String, val repeating: String, val disk: String, val recording: Boolean,
    val offersChanging: Boolean, val changeHeld: Boolean, val deleteHeld: Boolean, val problem: String,
)

data class WaitingReservation(
    val heading: String, val quality: String, val repeating: String, val disk: String, val problem: String,
    val notYet: String, val sendAgainHeld: Boolean, val deleteHeld: Boolean,
)

data class ProgrammeSheetScreen(
    val title: String, val station: String, val starts: String, val length: String, val genre: String,
    val summary: String, val extended: String, val waking: String,
    val recorders: HeldReservation?, val televisions: HeldReservation?,
    val waitingForTheRecorder: WaitingReservation?, val waitingForTheTelevision: WaitingReservation?,
    val asking: String, val held: Boolean, val offer: String,
    val destinations: List<Labelled>, val destinationAlone: String, val device: String,
    val disks: List<Labelled>, val disk: String, val diskAlone: String,
    val qualities: List<Labelled>, val quality: String, val qualityAlone: String,
    val repeats: List<Labelled>, val repeating: String,
    val checking: Boolean, val checkingLine: String, val conflictsLine: String, val clashes: Boolean,
    val conflicts: List<String>, val reserveHeld: Boolean, val problem: String, val asked: Asked?, val done: Boolean,
)

data class ReservationSheetScreen(
    val title: String, val station: String, val starts: String, val length: String, val waking: String,
    val onTelevision: Boolean, val settled: Boolean, val qualityValue: String, val repeatValue: String,
    val qualities: List<Labelled>, val quality: String, val repeats: List<Labelled>, val repeating: String,
    val disks: List<Labelled>, val disk: String, val diskAlone: String, val follows: String, val madeBy: String,
    val size: String, val recording: Boolean, val conflict: Boolean, val clashLine: String,
    val overlappingHeading: String, val overlapping: List<String>, val noneOverlapping: String,
    val madeByItself: String, val summary: String, val extended: String, val asking: String, val changed: Boolean,
    val changeLabel: String, val changeFooter: String, val buttonsHeld: Boolean, val problem: String,
    val asked: Asked?, val done: Boolean,
)

private fun labelled(list: Array<jp.hiroaki.bdbridge.bridge.Labelled>) = list.map { Labelled(it.code, it.label) }

private fun asked(present: Boolean, it: jp.hiroaki.bdbridge.bridge.Asked) =
    if (present) Asked(it.title, it.message, it.action, it.isDestructive, it.closing) else null

private fun held(present: Boolean, it: jp.hiroaki.bdbridge.bridge.HeldReservation) =
    if (present) HeldReservation(it.heading, it.quality, it.repeating, it.disk, it.isRecording, it.isOffersChanging,
                                 it.isChangeHeld, it.isDeleteHeld, it.problem) else null

private fun waiting(present: Boolean, it: jp.hiroaki.bdbridge.bridge.WaitingReservation) =
    if (present) WaitingReservation(it.heading, it.quality, it.repeating, it.disk, it.problem, it.notYet,
                                    it.isSendAgainHeld, it.isDeleteHeld) else null

private fun ProgrammeSheetScreen(it: jp.hiroaki.bdbridge.bridge.ProgrammeSheetScreen) = ProgrammeSheetScreen(
    it.title, it.station, it.starts, it.length, it.genre, it.summary, it.extended, it.waking,
    held(it.isHasRecorders, it.getRecorders(arena)), held(it.isHasTelevisions, it.getTelevisions(arena)),
    waiting(it.isHasWaitingForTheRecorder, it.getWaitingForTheRecorder(arena)),
    waiting(it.isHasWaitingForTheTelevision, it.getWaitingForTheTelevision(arena)),
    it.asking, it.isHeld, it.offer, labelled(it.getDestinations(arena)), it.destinationAlone, it.device,
    labelled(it.getDisks(arena)), it.disk, it.diskAlone, labelled(it.getQualities(arena)), it.quality, it.qualityAlone,
    labelled(it.getRepeats(arena)), it.repeating, it.isChecking, it.checkingLine, it.conflictsLine, it.isClashes,
    it.conflicts.toList(), it.isReserveHeld, it.problem, asked(it.isHasAsked, it.getAsked(arena)), it.isDone,
)

private fun ReservationSheetScreen(it: jp.hiroaki.bdbridge.bridge.ReservationSheetScreen) = ReservationSheetScreen(
    it.title, it.station, it.starts, it.length, it.waking, it.isOnTelevision, it.isSettled, it.qualityValue,
    it.repeatValue, labelled(it.getQualities(arena)), it.quality, labelled(it.getRepeats(arena)), it.repeating,
    labelled(it.getDisks(arena)), it.disk, it.diskAlone, it.follows, it.madeBy, it.size, it.isRecording, it.isConflict,
    it.clashLine, it.overlappingHeading, it.overlapping.toList(), it.noneOverlapping, it.madeByItself, it.summary,
    it.extended, it.asking, it.isChanged, it.changeLabel, it.changeFooter, it.isButtonsHeld, it.problem,
    asked(it.isHasAsked, it.getAsked(arena)), it.isDone,
)
