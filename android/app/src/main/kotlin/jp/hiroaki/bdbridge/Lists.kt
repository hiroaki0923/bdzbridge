package jp.hiroaki.bdbridge

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.VideoLibrary
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

// The reservations and the recordings as the iOS lists show them, for reading: their sheets, their sorting and
// narrowing, and pulling down come with the screens' own steps.

/** The reservations, the ones waiting on this device first, then by day under headings that stay as the list scrolls. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ReservationsScreen(search: () -> Unit) {
    val shown = RecBridge.reservations.collectAsState().value ?: return
    LaunchedEffect(shown.loadKey) { RecBridge.act { it.reservations.load() } }
    LaunchedEffect(Unit) { RecBridge.act { it.reservations.loadTV() } }
    var opened by remember { mutableStateOf<ReservationItem?>(null) }
    opened?.let { row -> ReservationSheetView(row.title, open = { RecBridge.openReservation(row.id) }) { opened = null } }
    Scaffold(topBar = {
        Column {
            TopAppBar(title = { TitleWithSubtitle("予約", if (shown.hasNoRecorder) "" else shown.subtitle) },
                      actions = { AppMenu(search) })
            StripBar()
        }
    }, bottomBar = { Line(shown.line, shown.lineIsAProblem) }) { padding ->
        Box(Modifier.padding(padding)) {
            if (shown.hasNoRecorder) return@Box NoRecorderView(Icons.Outlined.Schedule, shown.noRecorder, search)
            LazyColumn(Modifier.fillMaxSize()) {
                if (shown.waiting.isNotEmpty()) {
                    heading("送信待ち ${shown.waiting.size} 件")
                    items(shown.waiting, key = { "waiting-" + it.id }) { waiting -> WaitingRow(waiting) }
                    if (shown.waitingSays.isNotEmpty()) {
                        item(key = "waiting-says") { Footnote(shown.waitingSays, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
                    }
                }
                for (section in shown.sections) {
                    heading(section.title)
                    items(section.rows, key = { it.id }) { row -> ReservationRow(row) { opened = row } }
                }
            }
            if (shown.isEmpty) Unavailable(Icons.Outlined.Schedule, shown.emptyTitle, shown.emptyDetail)
        }
    }
}

/** A heading that stays at the top while its rows scroll under it. */
@OptIn(ExperimentalFoundationApi::class)
private fun LazyListScope.heading(title: String) {
    stickyHeader(key = "heading-$title") {
        Surface(color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
            Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                 modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
        }
    }
}

/** One reservation, as the iOS row says it: when and how long, marked, the title, then the station and how it records. */
@Composable
private fun ReservationRow(item: ReservationItem, open: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val marks = LocalMarks.current
    ListItem(
        overlineContent = {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("${item.time} · ${item.length}")
                if (item.recording) Mark("録画中", colors.errorContainer, colors.onErrorContainer)
                if (item.conflict) Mark("重複", marks.reserved, marks.onReserved)
                if (item.byTheRecorder) Mark("おまかせ", colors.surfaceContainerHighest, colors.onSurfaceVariant)
            }
        },
        headlineContent = { Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(item.details) },
        modifier = Modifier.clickable(onClick = open),
    )
    HorizontalDivider()
}

/** A reservation the device has not heard yet: what was asked for, and what the device said if it refused it. */
@Composable
private fun WaitingRow(item: Waiting) {
    val marks = LocalMarks.current
    ListItem(
        leadingContent = { Icon(Icons.Outlined.Schedule, contentDescription = null, tint = marks.onReserved) },
        headlineContent = { Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column {
                Text(item.details)
                if (item.problem.isNotEmpty()) Text(item.problem, color = MaterialTheme.colorScheme.error)
            }
        },
    )
    HorizontalDivider()
}

/** The recordings, newest first, with the free space in the top app bar. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordingsScreen(search: () -> Unit) {
    val shown = RecBridge.recordings.collectAsState().value ?: return
    LaunchedEffect(shown.loadKey) { RecBridge.act { it.recordings.load() } }
    LaunchedEffect(shown.tvKey) { RecBridge.act { it.recordings.loadTV() } }
    LaunchedEffect(shown.outdatedKey) { RecBridge.act { it.recordings.loadOutdated() } }
    Scaffold(topBar = {
        Column {
            TopAppBar(title = { TitleWithSubtitle(shown.heading, if (shown.hasNoRecorder || shown.isLoading) "" else shown.subtitle) },
                      actions = { AppMenu(search) })
            StripBar()
        }
    }, bottomBar = { Line(shown.line, shown.lineIsAProblem) }) { padding ->
        Box(Modifier.padding(padding)) {
            when {
                shown.hasNoRecorder -> NoRecorderView(Icons.Outlined.VideoLibrary, shown.noRecorder, search)
                shown.isLoading -> Unavailable(Icons.Outlined.VideoLibrary, shown.loadingTitle, shown.loadingDetail)
                else -> {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(shown.rows, key = { it.id }) { row -> RecordingRow(row) }
                    }
                    if (shown.rows.isEmpty()) Unavailable(Icons.Outlined.VideoLibrary, shown.emptyTitle, shown.emptyDetail)
                }
            }
        }
    }
}

/** One recording, as the iOS row says it: the lock and 録画中 before the title, then when, where and how, then whether it was watched. */
@Composable
private fun RecordingRow(item: RecordingItem) {
    val colors = MaterialTheme.colorScheme
    ListItem(
        headlineContent = {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                if (item.protected) Icon(Icons.Default.Lock, contentDescription = "保護", Modifier.size(14.dp), tint = colors.onSurfaceVariant)
                if (item.recording) Mark("録画中", colors.errorContainer, colors.onErrorContainer)
                Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(item.details)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(item.watched, color = if (item.unwatched) colors.primary else colors.onSurfaceVariant)
                    if (item.genre.isNotEmpty()) Text(item.genre)
                }
            }
        },
    )
    HorizontalDivider()
}

/** The recorder's line while it works, or what went wrong, at the foot of a list. */
@Composable
private fun Line(line: String, problem: Boolean) {
    if (line.isEmpty()) return
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Text(line, color = if (problem) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
             style = MaterialTheme.typography.bodyMedium, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp))
    }
}
