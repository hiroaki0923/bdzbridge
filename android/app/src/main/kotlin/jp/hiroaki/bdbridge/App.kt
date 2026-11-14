package jp.hiroaki.bdbridge

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.VideoLibrary
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.clearAndSetSemantics
import kotlinx.coroutines.launch

/**
 * The app: where a recorder is chosen, over the guide, the reservations and the recordings. The place to choose opens
 * by itself while nothing is set up, as the app starts, as the iOS app's tutorial does, and closes once a recorder
 * chosen there answers.
 */
@Composable
fun App() {
    val devices by RecBridge.devices.collectAsState()
    val shown = devices ?: return Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
    // Decided once, as the iOS app decides it, so that leaving the demo started with does not open it.
    var choosing by rememberSaveable { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(Unit) { if (choosing == null) choosing = shown.welcomes }
    val scope = rememberCoroutineScope()
    val close = {
        choosing = false
        scope.launch { RecBridge.act { it.devices.closed() } }
        Unit
    }
    LaunchedEffect(shown.chosenAnswered) { if (shown.chosenAnswered) close() }
    if (choosing ?: shown.welcomes) DevicesScreen(shown, close) else RecorderScreen { choosing = true }
}

/** The screens the navigation goes between, as the iOS app's tabs. */
enum class Destination(val label: String, val icon: ImageVector, val selectedIcon: ImageVector) {
    Guide("番組表", Icons.Outlined.GridView, Icons.Filled.GridView),
    Search("検索", Icons.Outlined.Search, Icons.Filled.Search),
    Reservations("予約", Icons.Outlined.Schedule, Icons.Filled.Schedule),
    Recordings("録画", Icons.Outlined.VideoLibrary, Icons.Filled.VideoLibrary),
    Settings("設定", Icons.Outlined.Settings, Icons.Filled.Settings),
}

/** A page over the destinations, with the way back: the stations' settings, ご利用上の注意, and the television's 対応状況. */
enum class Page { Channels, Disclaimer, Capabilities }

/**
 * The destinations, with Material's navigation for the width: a bar along the foot of a phone, a rail down the side
 * of anything wider (600 dp, Material's medium width). Each screen has its own top app bar, and all but the settings
 * the strip under it, as on iOS. A page opened from one of them goes over the whole, the navigation and all.
 */
@Composable
fun RecorderScreen(search: () -> Unit) {
    var page by rememberSaveable { mutableStateOf<Page?>(null) }
    // A programme of the recordings' まとめ, whose page goes over the whole as the others do: under it, the navigation
    // would take the reader away from a page whose request is still out.
    var group by remember { mutableStateOf<GroupItem?>(null) }
    Box(Modifier.fillMaxSize()) {
        Box(if (page != null || group != null) Modifier.clearAndSetSemantics {} else Modifier) {
            Destinations(search, { page = it }) { group = it }
        }
        when (page) {
            Page.Channels -> ChannelsPage { page = null }
            Page.Disclaimer -> DisclaimerPage { page = null }
            Page.Capabilities -> CapabilitiesPage { page = null }
            null -> {}
        }
        group?.let { programme -> GroupPage(programme) { group = null } }
    }
}

@Composable
private fun Destinations(search: () -> Unit, open: (Page) -> Unit, openGroup: (GroupItem) -> Unit) {
    val scope = rememberCoroutineScope()
    var destination by rememberSaveable { mutableStateOf(Destination.Guide) }
    val select = { chosen: Destination ->
        // The guide, chosen while it is showing, goes back to what is on now, as on iOS.
        if (chosen == destination && chosen == Destination.Guide) scope.launch { RecBridge.act { it.guide.goToNow() } }
        destination = chosen
    }
    val screen = @Composable {
        when (destination) {
            Destination.Guide -> GuideScreen(search) { open(Page.Channels) }
            Destination.Search -> SearchScreen()
            Destination.Reservations -> ReservationsScreen(search)
            Destination.Recordings -> RecordingsScreen(search, openGroup)
            Destination.Settings -> SettingsScreen({ open(Page.Channels) }, { open(Page.Disclaimer) }) { open(Page.Capabilities) }
        }
    }
    if (LocalConfiguration.current.screenWidthDp >= 600) {
        Row(Modifier.fillMaxSize()) {
            NavigationRail {
                for (each in Destination.entries) {
                    NavigationRailItem(selected = destination == each, onClick = { select(each) },
                                       icon = { Icon(if (destination == each) each.selectedIcon else each.icon, contentDescription = null) },
                                       label = { Text(each.label) })
                }
            }
            Box(Modifier.weight(1f)) { screen() }
        }
    } else {
        Scaffold(contentWindowInsets = WindowInsets(0), bottomBar = {
            NavigationBar {
                for (each in Destination.entries) {
                    NavigationBarItem(selected = destination == each, onClick = { select(each) },
                                      icon = { Icon(if (destination == each) each.selectedIcon else each.icon, contentDescription = null) },
                                      label = { Text(each.label) })
                }
            }
        }) { padding ->
            Box(Modifier.padding(padding).consumeWindowInsets(padding)) { screen() }
        }
    }
}
