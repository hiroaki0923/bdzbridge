package jp.hiroaki.bdbridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.concurrent.CompletableFuture
import jp.hiroaki.bdbridge.bridge.AndroidBridge
import jp.hiroaki.bdbridge.bridge.ChannelsWindow
import jp.hiroaki.bdbridge.bridge.DevicesWindow
import jp.hiroaki.bdbridge.bridge.GuideWindow
import jp.hiroaki.bdbridge.bridge.HelperRegisterWindow
import jp.hiroaki.bdbridge.bridge.ProgrammeSheetWindow
import jp.hiroaki.bdbridge.bridge.RecBridgeApp
import jp.hiroaki.bdbridge.bridge.RecordingsWindow
import jp.hiroaki.bdbridge.bridge.ReservationSheetWindow
import jp.hiroaki.bdbridge.bridge.ReservationsWindow
import jp.hiroaki.bdbridge.bridge.ScreenListener
import jp.hiroaki.bdbridge.bridge.SearchWindow
import jp.hiroaki.bdbridge.bridge.SettingsWindow
import jp.hiroaki.bdbridge.bridge.StripWindow
import jp.hiroaki.bdbridge.bridge.TVRegisterWindow
import jp.hiroaki.bdbridge.bridge.TitleSheetWindow
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
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
        val settings: SettingsWindow, val search: SearchWindow,
    )

    private val _devices = MutableStateFlow<Devices?>(null)
    private val _guide = MutableStateFlow<Guide?>(null)
    private val _reservations = MutableStateFlow<Reservations?>(null)
    private val _recordings = MutableStateFlow<Recordings?>(null)
    private val _strip = MutableStateFlow<Strip?>(null)
    private val _settings = MutableStateFlow<Settings?>(null)
    private val _search = MutableStateFlow<Search?>(null)
    val devices: StateFlow<Devices?> = _devices
    val guide: StateFlow<Guide?> = _guide
    val reservations: StateFlow<Reservations?> = _reservations
    val recordings: StateFlow<Recordings?> = _recordings
    val strip: StateFlow<Strip?> = _strip
    val settings: StateFlow<Settings?> = _settings
    val search: StateFlow<Search?> = _search

    /**
     * Runs `work` where nothing a screen does cancels it: for what has to finish whatever becomes of the screen that
     * asked, as a sheet's window opened for a sheet already closed is closed in turn.
     */
    fun launch(work: suspend () -> Unit) {
        scope.launch { work() }
    }

    /** Whether the model has been asked to open in this process. */
    val isOpen: Boolean get() = opening

    /**
     * Opens the model the first time it is asked, with the app's folder and the folder of its that never leaves the
     * device -- no backup and no move to another device takes it -- where the television's registration is kept, and
     * starts it.
     */
    fun open(context: Context) {
        if (opening) return
        opening = true
        val files = context.filesDir.absolutePath
        val kept = context.noBackupFilesDir.absolutePath
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val version = "${info.versionName} (${info.longVersionCode})"
        scope.launch {
            val app = call { RecBridgeApp.open(files, kept, version, arena) }
            val windows = Windows(app, app.devices(arena), app.guide(arena), call { app.reservations(arena) },
                                  app.recordings(arena), app.strip(arena), call { app.settings(arena) },
                                  call { app.search(arena) })
            watch({ windows.devices.observe(it) }, { Devices(call { windows.devices.read(arena) }) }, _devices)
            watch({ windows.guide.observe(it) }, { Guide(call { windows.guide.read(arena) }) }, _guide)
            watch({ windows.reservations.observe(it) }, { Reservations(call { windows.reservations.read(arena) }) }, _reservations)
            watch({ windows.recordings.observe(it) }, { Recordings(call { windows.recordings.read(arena) }) }, _recordings)
            watch({ windows.strip.observe(it) }, { Strip(call { windows.strip.read(arena) }) }, _strip)
            watch({ windows.settings.observe(it) }, { Settings(call { windows.settings.read(arena) }) }, _settings)
            watch({ windows.search.observe(it) }, { Search(call { windows.search.read(arena) }) }, _search)
            // The box starts with what the model has in it; nothing but the reader changes it after that.
            launch { searchField.follow(search.filterNotNull().first().query, 0) }
            launch {
                settings.collect { shown ->
                    shown ?: return@collect
                    hostField.follow(shown.typedHost, shown.hostSet)
                    macField.follow(shown.typedMac, shown.macSet)
                }
            }
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
     * What the reader types into the settings' fields, and the presses that go by what was typed, sent to Swift one
     * after the other in the order they were made: sent each on its own, a later keystroke could reach Swift before an
     * earlier one, and a connect before the address it was pressed for. A press answers once begun, so nothing typed
     * after it waits for the connect.
     */
    private val typing = Channel<suspend (SettingsWindow) -> Unit>(Channel.UNLIMITED).also { operations ->
        scope.launch { for (operation in operations) operation(windows().settings) }
    }

    /**
     * One of the settings' fields as the reader sees it, kept here for as long as the model is, as the iOS screen keeps
     * its fields: a screen made again -- the field scrolled away and back, the settings left and come back to -- shows
     * what was typed, whether or not it has reached Swift yet. What is typed goes to Swift with the field's count it
     * was typed over (`Settings.hostSet`), and Swift drops a keystroke typed over a value the model has replaced
     * since; the field takes the model's value when that count moves.
     */
    class Field(private val send: (String, Long) -> Unit) {
        private val _text = MutableStateFlow("")
        val text: StateFlow<String> = _text
        /**
         * The same text where Compose reads it in the turn it was typed: a field drawn from the flow gets it a moment
         * later, which is enough to lose the letters an input method is still composing, as it composes kana.
         */
        var typed by mutableStateOf("")
            private set
        private var seen = -1L

        fun type(value: String) {
            typed = value
            _text.value = value
            send(value, seen)
        }

        internal fun follow(value: String, set: Long) {
            if (set == seen) return
            seen = set
            typed = value
            _text.value = value
        }
    }

    val hostField = Field { text, seen -> typing.trySend { window -> call<Void> { window.typeHost(text, seen) } } }
    val macField = Field { text, seen -> typing.trySend { window -> call<Void> { window.typeMac(text, seen) } } }

    /** A press of the settings that goes by what was typed: sent after every keystroke made before it. */
    fun afterTyping(operation: (SettingsWindow) -> CompletableFuture<*>) {
        typing.trySend { window -> call<Any?> { operation(window).thenApply { it } } }
    }

    /**
     * The recordings screen has come on or gone, told in the order it happened: while it is on, Swift waits for a
     * television's list that may still be coming, and a quick leave and return told the other way round would leave
     * it waiting for a screen that has gone, or not waiting for one that is there.
     */
    fun recordingsShown(on: Boolean) {
        recordingsSightings.trySend(on)
    }

    private val recordingsSightings = Channel<Boolean>(Channel.UNLIMITED).also { changes ->
        scope.launch {
            for (on in changes) {
                val recordings = windows().recordings
                call<Void> { recordings.shown(on) }
            }
        }
    }

    /**
     * What the reader does on the search screen -- the words typed, the scope picked -- and the screen's coming on and
     * going, sent to Swift one after the other in the order they happened: Swift searches and reads for as long as the
     * screen is on, by what is in the box and the scope then.
     */
    private val searching = Channel<suspend (SearchWindow) -> Unit>(Channel.UNLIMITED).also { operations ->
        scope.launch { for (operation in operations) operation(windows().search) }
    }

    val searchField = Field { text, _ -> searching.trySend { window -> call<Void> { window.type(text) } } }

    fun searchScope(code: String) {
        searching.trySend { window -> call<Void> { window.chooseScope(code) } }
    }

    fun searchShown(on: Boolean) {
        searching.trySend { window -> call<Void> { window.shown(on) } }
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

    /** The sheet of a recording in the list, opened: nil when the list no longer has it. */
    suspend fun openRecording(id: String): TitleSheetHandle? =
        ask { it.recordings.open(id, arena) }.orElse(null)?.let { TitleSheetHandle(it) }

    /** The sheet of a reservation in the list, opened: nil when the list no longer has it. */
    suspend fun openReservation(id: String): ReservationSheetHandle? =
        ask { it.reservations.open(id, arena) }.orElse(null)?.let { ReservationSheetHandle(it) }

    /** The sheets of what the search found, opened: nil when what was found has gone since. */
    suspend fun openFoundProgramme(id: String): ProgrammeSheetHandle? =
        ask { it.search.openProgramme(id, arena) }.orElse(null)?.let { ProgrammeSheetHandle(it) }

    suspend fun openFoundReservation(id: String): ReservationSheetHandle? =
        ask { it.search.openReservation(id, arena) }.orElse(null)?.let { ReservationSheetHandle(it) }

    suspend fun openFoundRecording(id: String): TitleSheetHandle? =
        ask { it.search.openRecording(id, arena) }.orElse(null)?.let { TitleSheetHandle(it) }

    /** Which stations the guide shows and in what order, opened at the broadcasting type the guide is on. */
    suspend fun openChannels(): ChannelsHandle = ChannelsHandle(ask { it.app.channels(arena) })

    /**
     * The sheet that adds a television at `host` -- a television a search found, going straight on to it, or an
     * address to type -- or registers with the one added again.
     */
    suspend fun openTVRegister(host: String, connectAtOnce: Boolean, again: Boolean): TVRegisterHandle =
        TVRegisterHandle(ask { it.app.registerTV(host, connectAtOnce, again, arena) })

    /** The same sheet, registering with the television added again: the strip's 登録 and the settings' 登録する. */
    suspend fun openTVRegisterAgain(): TVRegisterHandle = TVRegisterHandle(ask { it.app.registerTVAgain(arena) })

    /** The sheet that registers with the helper on the television added. */
    suspend fun openHelperRegister(): HelperRegisterHandle = HelperRegisterHandle(ask { it.app.registerHelper(arena) })

    /** 対応状況を調べる: what the television added says it speaks, as text to copy. */
    suspend fun tvCapabilities(): String = ask { it.settings.tvCapabilities() }

    /** ご利用上の注意, as the model words it. */
    suspend fun disclaimer(): Disclaimer = windows().settings.disclaimer(arena).let { text ->
        Disclaimer(text.title, text.opening, text.getSections(arena).map { Fact(it.label, it.value) }, text.link, text.url)
    }

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
        suspend fun act(key: String) = call<Void> { window.act(key) }.let {}
        suspend fun closeAsked(key: String) = call<Void> { window.closeAsked(key) }.let {}
        /** 予約を変更する: the reservation's own sheet, over this one. */
        suspend fun change(device: String): ReservationSheetHandle? =
            call { window.change(device, arena) }.orElse(null)?.let { ReservationSheetHandle(it) }
        suspend fun changeClosed() = call<Void> { window.changeClosed() }.let {}
    }

    class TitleSheetHandle(private val window: TitleSheetWindow) :
        Sheet<TitleSheetScreen>({ window.observe(it) }, { TitleSheetScreen(call { window.read(arena) }) }) {
        override suspend fun ended() = call<Void> { window.closed() }.let {}
        suspend fun play(operation: String) = call<Void> { window.play(operation) }.let {}
        suspend fun powerOn() = call<Void> { window.powerOn() }.let {}
        suspend fun setProtected(on: Boolean) = call<Void> { window.setProtected(on) }.let {}
        suspend fun delete() = call<Void> { window.delete() }.let {}
        suspend fun confirmDelete(key: String) = call<Void> { window.confirmDelete(key) }.let {}
        suspend fun closeAsked(key: String) = call<Void> { window.closeAsked(key) }.let {}
    }

    class ChannelsHandle(private val window: ChannelsWindow) :
        Sheet<Channels>({ window.observe(it) }, { Channels(call { window.read(arena) }) }) {
        override suspend fun ended() = call<Void> { window.closed() }.let {}
        suspend fun choose(broadcasting: String) = call<Void> { window.choose(broadcasting) }.let {}
        suspend fun show(id: String, on: Boolean) = call<Void> { window.show(id, on) }.let {}
        /** Whether it was moved: refused for a list read again since the drag began. */
        suspend fun move(id: String, from: Int, to: Int): Boolean = call { window.move(id, from.toLong(), to.toLong()) }
        suspend fun reset() = call<Void> { window.reset() }.let {}
        suspend fun failureClosed() = call<Void> { window.failureClosed() }.let {}
    }

    /**
     * The television's sheet. What is typed and pressed goes to Swift one after the other in the order it was done, as
     * the settings' fields do: a press after the keystrokes it was pressed over, and the sheet's closing after them
     * all, so that no press reaches Swift after the sheet has gone -- a step begun then would go on to the
     * registration, and put a number on the television's panel for nobody. The PIN field takes the model's value when
     * the model has emptied it -- a PIN turned down -- and Swift drops what was typed over the value before.
     */
    class TVRegisterHandle(private val window: TVRegisterWindow) :
        Sheet<TVRegisterScreen>({ window.observe(it) }, { TVRegisterScreen(call { window.read(arena) }) }) {
        private val inTurn = Channel<suspend () -> Unit>(Channel.UNLIMITED).also { operations ->
            scope.launch { for (operation in operations) operation() }
        }
        val pinField = Field { text, seen -> inTurn.trySend { call<Void> { window.typePIN(text, seen) } } }
        private val following = scope.launch {
            shown.collect { it?.let { screen -> pinField.follow(screen.pin, screen.pinSet) } }
        }

        override suspend fun ended() {
            following.cancel()
            inTurn.send { call<Void> { window.closed() } }
            inTurn.close()
        }
        fun appeared() = inTurn.trySend { call<Void> { window.appeared() } }.let {}
        fun typeHost(text: String) = inTurn.trySend { call<Void> { window.typeHost(text) } }.let {}
        fun press() = inTurn.trySend { call<Void> { window.press() } }.let {}
    }

    /** The helper's sheet, its keystrokes, its press and its closing in the order they were made. */
    class HelperRegisterHandle(private val window: HelperRegisterWindow) :
        Sheet<HelperRegisterScreen>({ window.observe(it) }, { HelperRegisterScreen(call { window.read(arena) }) }) {
        private val inTurn = Channel<suspend () -> Unit>(Channel.UNLIMITED).also { operations ->
            scope.launch { for (operation in operations) operation() }
        }

        override suspend fun ended() {
            inTurn.send { call<Void> { window.closed() } }
            inTurn.close()
        }
        fun typeCode(text: String) = inTurn.trySend { call<Void> { window.typeCode(text) } }.let {}
        fun press() = inTurn.trySend { call<Void> { window.press() } }.let {}
    }

    class ReservationSheetHandle(private val window: ReservationSheetWindow) :
        Sheet<ReservationSheetScreen>({ window.observe(it) }, { ReservationSheetScreen(call { window.read(arena) }) }) {
        override suspend fun ended() = call<Void> { window.closed() }.let {}
        suspend fun chooseQuality(code: String) = call<Void> { window.chooseQuality(code) }.let {}
        suspend fun chooseRepeat(code: String) = call<Void> { window.chooseRepeat(code) }.let {}
        suspend fun chooseDisk(code: String) = call<Void> { window.chooseDisk(code) }.let {}
        suspend fun sendTheChange() = call<Void> { window.sendTheChange() }.let {}
        suspend fun delete() = call<Void> { window.delete() }.let {}
        suspend fun confirmDelete(key: String) = call<Void> { window.confirmDelete(key) }.let {}
        suspend fun closeAsked(key: String) = call<Void> { window.closeAsked(key) }.let {}
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
    val busy: String, val problem: String, val recorders: List<FoundRecorder>, val televisions: List<FoundTelevision>,
    val choosing: Boolean, val canChoose: Boolean, val demo: Boolean, val chosenAnswered: Boolean,
)

data class FoundRecorder(val host: String, val name: String, val details: String, val inUse: Boolean)

/** A television a search found: `registers` while no television is added, when a tap registers it. */
data class FoundTelevision(val host: String, val name: String, val inUse: Boolean, val registers: Boolean)

private fun televisions(list: Array<jp.hiroaki.bdbridge.bridge.FoundTelevision>) =
    list.map { FoundTelevision(it.host, it.name, it.isInUse, it.isRegisters) }

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

/**
 * The reservations (`ReservationsWindow`): the menu's 種類 and 並び順, the rows that wait on this device and the list
 * under its headings, and the one question or answer up at a time. `staleKey` moves when a device's old list does:
 * what is said of it is read each minute.
 */
data class Reservations(
    val hasNoRecorder: Boolean, val noRecorder: NoRecorder, val isEmpty: Boolean, val emptyTitle: String,
    val emptyDetail: String, val subtitle: String, val kinds: List<Labelled>, val kind: String,
    val sorts: List<Labelled>, val sort: String, val filtering: Boolean, val staleKey: String,
    val waitingHeading: String, val waiting: List<Waiting>, val waitingSays: String, val sections: List<Section>,
    val asked: Asked?, val line: String, val lineIsAProblem: Boolean, val loadKey: String,
)

data class Section(val title: String, val rows: List<ReservationItem>)

data class ReservationItem(
    val id: String, val time: String, val length: String, val recording: Boolean, val conflict: Boolean,
    val byTheRecorder: Boolean, val title: String, val details: String, val deleteHeld: Boolean,
)

/** A row that waits on this device: `held` while the device it waits for works, when neither swipe does anything. */
data class Waiting(
    val id: String, val title: String, val details: String, val problem: String, val offersSendingAgain: Boolean,
    val held: Boolean,
)

data class Recordings(
    val hasNoRecorder: Boolean, val noRecorder: NoRecorder, val isLoading: Boolean, val loadingTitle: String,
    val loadingDetail: String, val emptyTitle: String, val emptyDetail: String, val heading: String,
    val subtitle: String, val destinations: List<Labelled>, val destination: String, val genres: List<Labelled>,
    val genre: String, val sorts: List<Labelled>, val sort: String, val states: List<Labelled>, val state: String,
    val filtering: Boolean, val tvNote: String, val rows: List<RecordingItem>, val line: String,
    val lineIsAProblem: Boolean, val loadKey: String, val tvKey: String, val outdatedKey: String,
)

data class RecordingItem(
    val id: String, val title: String, val recording: Boolean, val protected: Boolean, val details: String,
    val watched: String, val unwatched: Boolean, val genre: String,
)

private fun Programme(row: jp.hiroaki.bdbridge.bridge.GuideRow) =
    Programme(row.id, row.serviceID, row.time, row.length, row.title, row.station, row.mark, row.isMarkIsRed, row.genre,
              row.summary, row.starts, row.ends)

private fun ReservationItem(row: jp.hiroaki.bdbridge.bridge.ReservationRow) =
    ReservationItem(row.id, row.time, row.length, row.isRecording, row.isConflict, row.isByTheRecorder, row.title,
                    row.details, row.isDeleteHeld)

private fun RecordingItem(row: jp.hiroaki.bdbridge.bridge.RecordingRow) =
    RecordingItem(row.id, row.title, row.isRecording, row.isProtected, row.details, row.watched, row.isUnwatched,
                  row.genre)

/**
 * The search (`SearchWindow`): what is said in place of the results, or what was found in the scope picked. A
 * programme found says its day, being of any day of the guide, and for one found only in its details, the words found.
 */
data class Search(
    val shows: String, val title: String, val detail: String, val scopes: List<Labelled>, val scope: String,
    val prompt: String, val query: String, val countLine: String, val moreLine: String,
    val programmes: List<FoundProgramme>, val logos: Map<String, ByteArray>, val reservations: List<ReservationItem>,
    val recordings: List<RecordingItem>,
)

data class FoundProgramme(
    val row: Programme, val day: String, val logo: String, val before: String, val match: String, val after: String,
    val hasSnippet: Boolean,
)

private fun Search(it: jp.hiroaki.bdbridge.bridge.SearchScreen) = it.getSaid(arena).let { said ->
    Search(
        it.shows, said.title, said.detail, labelled(it.getScopes(arena)), it.scope, it.prompt, it.query, it.countLine,
        it.moreLine,
        it.getProgrammes(arena).map { found ->
            FoundProgramme(Programme(found.getRow(arena)), found.day, found.logo, found.before, found.match, found.after,
                           found.isHasSnippet)
        },
        it.getLogos(arena).associate { logo -> logo.key to logo.image },
        it.getReservations(arena).map { row -> ReservationItem(row) },
        it.getRecordings(arena).map { row -> RecordingItem(row) },
    )
}

private fun NoRecorder(said: jp.hiroaki.bdbridge.bridge.NoRecorder) =
    said.getSaid(arena).let { NoRecorder(said.kind, it.title, it.detail) }

private fun Devices(it: jp.hiroaki.bdbridge.bridge.DevicesScreen) = Devices(
    it.isWelcomes, it.isSearching, it.searched, it.toSearch, it.outcome, it.isOutcomeFailed, it.outcomeNote,
    it.causes.toList(), it.busy, it.problem,
    it.getRecorders(arena).map { found -> FoundRecorder(found.host, found.name, found.details, found.isInUse) },
    televisions(it.getTelevisions(arena)), it.isChoosing, it.isCanChoose, it.isDemo, it.isChosenAnswered,
)

private fun Guide(it: jp.hiroaki.bdbridge.bridge.GuideScreen) = it.getSaid(arena).let { said ->
    Guide(
        it.shows, NoRecorder(it.getNoRecorder(arena)), said.title, said.detail, it.offers, it.heading,
        it.getBroadcastings(arena).map { choice -> Choice(choice.code, choice.label) }, it.broadcasting,
        it.getStations(arena).map { station -> Station(station.serviceID, station.name, station.logo) }, it.station,
        it.days.toList(), it.day.toInt(),
        it.getProgrammes(arena).map { row -> Programme(row) },
        it.nowRequests, it.isCanRefresh, it.isDemo,
    )
}

private fun Reservations(it: jp.hiroaki.bdbridge.bridge.ReservationsScreen) = it.getEmpty(arena).let { empty ->
    Reservations(
        it.isHasNoRecorder, NoRecorder(it.getNoRecorder(arena)), it.isEmpty, empty.title, empty.detail, it.subtitle,
        labelled(it.getKinds(arena)), it.kind, labelled(it.getSorts(arena)), it.sort, it.isFiltering, it.staleKey,
        it.waitingHeading,
        it.getWaiting(arena).map { row ->
            Waiting(row.id, row.title, row.details, row.problem, row.isOffersSendingAgain, row.isHeld)
        },
        it.waitingSays,
        it.getSections(arena).map { section ->
            Section(section.title, section.getRows(arena).map { row -> ReservationItem(row) })
        },
        asked(it.isHasAsked, it.getAsked(arena)), it.line, it.isLineIsAProblem, it.loadKey,
    )
}

private fun Recordings(it: jp.hiroaki.bdbridge.bridge.RecordingsScreen): Recordings {
    val loading = it.getLoading(arena)
    val empty = it.getEmpty(arena)
    return Recordings(
        it.isHasNoRecorder, NoRecorder(it.getNoRecorder(arena)), it.isLoading, loading.title, loading.detail,
        empty.title, empty.detail, it.heading, it.subtitle, labelled(it.getDestinations(arena)), it.destination,
        labelled(it.getGenres(arena)), it.genre, labelled(it.getSorts(arena)), it.sort, labelled(it.getStates(arena)),
        it.state, it.isFiltering, it.tvNote,
        it.getRows(arena).map { row -> RecordingItem(row) },
        it.line, it.isLineIsAProblem, it.loadKey, it.tvKey, it.outdatedKey,
    )
}

/** The strip at the top of every screen (`StripWindow`): `kind` is empty when it has nothing to say. */
data class Strip(val kind: String, val text: String, val inFull: Boolean, val action: String, val actionEnabled: Boolean)

private fun Strip(it: jp.hiroaki.bdbridge.bridge.StripLine) =
    Strip(it.kind, it.text, it.isInFull, it.action, it.isActionEnabled)


/** A value with its words, as a picker offers it. */
data class Labelled(val code: String, val label: String)

/**
 * The one question or answer up at a time on a sheet. `action` is empty where there is only the closing button; `key`
 * goes back with a press, which does nothing once another question has taken this one's place.
 */
data class Asked(val key: String, val title: String, val message: String, val action: String, val destructive: Boolean, val closing: String)

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
    if (present) Asked(it.key, it.title, it.message, it.action, it.isDestructive, it.closing) else null

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

data class TitleSheetScreen(
    val title: String, val station: String, val recorded: String, val length: String, val size: String,
    val quality: String, val disk: String, val viewing: String, val genre: String, val offersPlayback: Boolean,
    val playLabel: String, val playHeld: Boolean, val playbackHeld: Boolean, val offersPower: Boolean,
    val playbackNote: String, val protected: Boolean, val protectLabel: String, val protectHeld: Boolean,
    val deleteHeld: Boolean, val whyNotDeleted: String, val summary: String, val details: List<String>,
    val line: String, val problem: String, val asking: Boolean, val asked: Asked?, val actionHeld: Boolean,
    val done: Boolean,
)

private fun TitleSheetScreen(it: jp.hiroaki.bdbridge.bridge.TitleSheetScreen) = TitleSheetScreen(
    it.title, it.station, it.recorded, it.length, it.size, it.quality, it.disk, it.viewing, it.genre,
    it.isOffersPlayback, it.playLabel, it.isPlayHeld, it.isPlaybackHeld, it.isOffersPower, it.playbackNote,
    it.isProtected, it.protectLabel, it.isProtectHeld, it.isDeleteHeld, it.whyNotDeleted, it.summary,
    it.details.toList(), it.line, it.problem, it.isAsking, asked(it.isHasAsked, it.getAsked(arena)), it.isActionHeld,
    it.isDone,
)

/** A label and what is said beside it. */
data class Fact(val label: String, val value: String)

/** The settings (`SettingsWindow`): the fields' `hostSet` and `macSet` move when the model sets them itself. */
data class Settings(
    val facts: List<Fact>, val standing: String, val typedHost: String, val hostSet: Long, val typedMac: String,
    val macSet: Long, val addressNote: String, val addressWarning: Boolean, val offersConnect: Boolean,
    val connectHeld: Boolean, val offersReconnect: Boolean, val reconnectHeld: Boolean, val qualities: List<Labelled>,
    val quality: String, val television: TelevisionPart, val searchHeld: Boolean, val searched: Long,
    val toSearch: Long, val outcome: String, val outcomeFailed: Boolean, val outcomeNote: String,
    val causes: List<String>, val recorders: List<FoundRecorder>, val televisions: List<FoundTelevision>,
    val canChoose: Boolean, val guideSources: List<Labelled>, val guideSource: String, val guideSourceAlone: String,
    val helperProblem: String, val guide: List<Fact>, val refreshHeld: Boolean, val demo: Boolean,
    val version: String, val busy: String, val problem: String, val phoneProblem: String,
)

/** The television's part of the settings (`TelevisionPart`): with one added, or the way to add one. */
data class TelevisionPart(
    val added: Boolean, val facts: List<Fact>, val offersRegistering: Boolean, val offersReconnect: Boolean,
    val reconnectHeld: Boolean, val offersTheHelper: Boolean, val helperRegistered: Boolean, val removeHeld: Boolean,
    val asksToRemove: Boolean, val removalQuestion: String, val removalMessage: String, val footer: String,
)

private fun TelevisionPart(it: jp.hiroaki.bdbridge.bridge.TelevisionPart) = TelevisionPart(
    it.isAdded, facts(it.getFacts(arena)), it.isOffersRegistering, it.isOffersReconnect, it.isReconnectHeld,
    it.isOffersTheHelper, it.isHelperRegistered, it.isRemoveHeld, it.isAsksToRemove, it.removalQuestion,
    it.removalMessage, it.footer,
)

/** The television's sheet (`TVRegisterWindow`): `pinSet` moves when the model has set the PIN field itself. */
data class TVRegisterScreen(
    val title: String, val typedHost: String, val addressHeld: Boolean, val askingForPIN: Boolean, val pin: String,
    val pinSet: Long, val pinNote: String, val turnedAway: String, val message: String, val pressLabel: String,
    val pressHeld: Boolean, val working: Boolean, val done: Boolean,
)

private fun TVRegisterScreen(it: jp.hiroaki.bdbridge.bridge.TVRegisterScreen) = TVRegisterScreen(
    it.title, it.typedHost, it.isAddressHeld, it.isAskingForPIN, it.pin, it.pinSet, it.pinNote, it.turnedAway,
    it.message, it.pressLabel, it.isPressHeld, it.isWorking, it.isDone,
)

data class HelperRegisterScreen(val pressHeld: Boolean, val working: Boolean, val message: String, val done: Boolean)

private fun HelperRegisterScreen(it: jp.hiroaki.bdbridge.bridge.HelperRegisterScreen) =
    HelperRegisterScreen(it.isPressHeld, it.isWorking, it.message, it.isDone)

private fun facts(list: Array<jp.hiroaki.bdbridge.bridge.Fact>) = list.map { Fact(it.label, it.value) }

private fun Settings(it: jp.hiroaki.bdbridge.bridge.SettingsScreen) = Settings(
    facts(it.getFacts(arena)), it.standing, it.typedHost, it.hostSet, it.typedMac, it.macSet, it.addressNote,
    it.isAddressWarning, it.isOffersConnect, it.isConnectHeld, it.isOffersReconnect, it.isReconnectHeld,
    labelled(it.getQualities(arena)), it.quality, TelevisionPart(it.getTelevision(arena)), it.isSearchHeld,
    it.searched, it.toSearch, it.outcome, it.isOutcomeFailed, it.outcomeNote, it.causes.toList(),
    it.getRecorders(arena).map { found -> FoundRecorder(found.host, found.name, found.details, found.isInUse) },
    televisions(it.getTelevisions(arena)), it.isCanChoose, labelled(it.getGuideSources(arena)), it.guideSource,
    it.guideSourceAlone, it.helperProblem, facts(it.getGuide(arena)), it.isRefreshHeld, it.isDemo, it.version,
    it.busy, it.problem, it.phoneProblem,
)

data class Disclaimer(val title: String, val opening: String, val sections: List<Fact>, val link: String, val url: String)

/** Which stations the guide shows and in what order (`ChannelsWindow`). */
data class Channels(
    val types: List<Labelled>, val broadcasting: String, val stations: List<ArrangedStation>, val loaded: Boolean,
    val emptyTitle: String, val emptyDetail: String, val customised: Boolean, val footer: String,
    val resetQuestion: String, val failure: String,
)

/** A station of the list, with the logo the recorder sent for it as an image file (empty when it never had one). */
class ArrangedStation(val id: String, val name: String, val logo: ByteArray, val shown: Boolean)

private fun Channels(it: jp.hiroaki.bdbridge.bridge.ChannelsScreen) = it.getEmpty(arena).let { empty ->
    Channels(
        labelled(it.getTypes(arena)), it.broadcasting,
        it.getStations(arena).map { station -> ArrangedStation(station.id, station.name, station.logo, station.isShown) },
        it.isLoaded, empty.title, empty.detail, it.isCustomised, it.footer, it.resetQuestion, it.failure,
    )
}
