package jp.hiroaki.bdbridge

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
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
            } catch (failure: BridgeFailure) {
                problem = failure.message
            }
            connecting = false
        }
    }

    fun connectToTheDemo() = connect(Bridge.demoHost)

    fun leave() {
        recorder = null
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
