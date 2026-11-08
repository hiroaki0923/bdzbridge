package jp.hiroaki.bdbridge

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** A list as it stands: being read, read, or what stopped it. */
sealed interface Loaded<out T> {
    data object Reading : Loaded<Nothing>
    data class Read<T>(val items: List<T>) : Loaded<T>
    data class Failed(val said: String) : Loaded<Nothing>
}

/**
 * The app's state for its screens: the recorder chosen, kept between launches, and what was read of it. Reads only;
 * nothing here wakes a recorder or writes to one.
 */
class AppState(application: Application) : AndroidViewModel(application) {
    private val saved = application.getSharedPreferences("recbridge", Context.MODE_PRIVATE)

    var address by mutableStateOf(saved.getString("host", "") ?: "")
    var searching by mutableStateOf(false)
        private set
    var found by mutableStateOf<List<Found>?>(null)
        private set
    var connecting by mutableStateOf(false)
        private set
    var problem by mutableStateOf<String?>(null)
        private set
    var recorder by mutableStateOf<Recorder?>(null)
        private set
    var reservations by mutableStateOf<Loaded<ReservationItem>>(Loaded.Reading)
        private set
    var recordings by mutableStateOf<Loaded<RecordingItem>>(Loaded.Reading)
        private set

    val isDemo: Boolean get() = recorder?.host == Bridge.demoHost

    // The guide: one broadcasting type, one station and one day at a time.
    private val folder: String = application.filesDir.absolutePath
    var broadcasting by mutableStateOf("td")
        private set
    var stations by mutableStateOf<Loaded<Station>>(Loaded.Reading)
        private set
    var station by mutableStateOf<Station?>(null)
        private set
    var dayOffset by mutableStateOf(0L)
        private set
    var programmes by mutableStateOf<Loaded<Programme>>(Loaded.Reading)
        private set
    var refreshing by mutableStateOf(false)
        private set
    var guideSaid by mutableStateOf<String?>(null)
        private set
    // The read under way, given up when another station or day is chosen so that a slower read cannot land after it.
    private var reading: Job? = null

    val dayHeading: String get() = Bridge.dayHeading(dayOffset)

    /** Fills the guide from the recorder (the demo's from its invented line-up), then reads the stations again. */
    fun refreshGuide() {
        val host = recorder?.host ?: return
        refreshing = true
        guideSaid = null
        viewModelScope.launch {
            guideSaid = try {
                Bridge.refreshGuide(host, folder)
            } catch (failure: BridgeFailure) {
                failure.message
            }
            refreshing = false
            readStations()
        }
    }

    fun choose(broadcasting: String) {
        this.broadcasting = broadcasting
        readStations()
    }

    fun choose(station: Station) {
        this.station = station
        readProgrammes()
    }

    fun moveDay(days: Long) {
        dayOffset = (dayOffset + days).coerceIn(0, 7)
        readProgrammes()
    }

    fun readStations() {
        val host = recorder?.host ?: return
        stations = Loaded.Reading
        viewModelScope.launch {
            stations = try {
                Loaded.Read(Bridge.channels(host, folder, broadcasting))
            } catch (failure: BridgeFailure) {
                Loaded.Failed(failure.message ?: "")
            }
            val read = (stations as? Loaded.Read)?.items.orEmpty()
            station = read.firstOrNull { it.serviceID == station?.serviceID } ?: read.firstOrNull()
            readProgrammes()
        }
    }

    private fun readProgrammes() {
        val host = recorder?.host ?: return
        val chosen = station ?: run { programmes = Loaded.Read(emptyList()); return }
        programmes = Loaded.Reading
        reading?.cancel()
        reading = viewModelScope.launch {
            programmes = try {
                Loaded.Read(Bridge.programmes(host, folder, broadcasting, chosen.serviceID, dayOffset))
            } catch (failure: BridgeFailure) {
                Loaded.Failed(failure.message ?: "")
            }
        }
    }

    fun search() {
        searching = true
        problem = null
        viewModelScope.launch {
            found = Bridge.search()
            searching = false
        }
    }

    fun connect(host: String) {
        connecting = true
        problem = null
        viewModelScope.launch {
            try {
                val described = Bridge.describe(host)
                recorder = described
                if (host != Bridge.demoHost) saved.edit().putString("host", host).apply()
                readLists()
                // The demo's guide is invented, and filled at once; a real recorder's is fetched when asked.
                if (host == Bridge.demoHost) refreshGuide() else readStations()
            } catch (failure: BridgeFailure) {
                problem = failure.message
            }
            connecting = false
        }
    }

    fun connectToTheDemo() = connect(Bridge.demoHost)

    fun leave() {
        recorder = null
        station = null
        dayOffset = 0
        guideSaid = null
        reservations = Loaded.Reading
        recordings = Loaded.Reading
    }

    /** Both lists, one after the other: a recorder answers one request at a time. */
    fun readLists() {
        val host = recorder?.host ?: return
        reservations = Loaded.Reading
        recordings = Loaded.Reading
        viewModelScope.launch {
            reservations = try {
                Loaded.Read(Bridge.reservations(host))
            } catch (failure: BridgeFailure) {
                Loaded.Failed(failure.message ?: "")
            }
            recordings = try {
                Loaded.Read(Bridge.recordings(host))
            } catch (failure: BridgeFailure) {
                Loaded.Failed(failure.message ?: "")
            }
        }
    }
}
