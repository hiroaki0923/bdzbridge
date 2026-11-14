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
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.FilterAlt
import androidx.compose.material.icons.outlined.FilterAlt
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch

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
            TopAppBar(title = { TitleWithSubtitle("予約", if (shown.hasNoRecorder) "" else shown.subtitle) })
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
internal fun ReservationRow(item: ReservationItem, open: () -> Unit) {
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

/**
 * The recordings, with the free space in the top app bar and the iOS screen's menu beside it: 録画先, ジャンル, 並び順
 * and 視聴状態. Pulled down, the list is read again from both devices.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordingsScreen(search: () -> Unit) {
    val shown = RecBridge.recordings.collectAsState().value ?: return
    val scope = rememberCoroutineScope()
    LaunchedEffect(shown.loadKey) { RecBridge.act { it.recordings.load() } }
    LaunchedEffect(shown.tvKey) { RecBridge.act { it.recordings.loadTV() } }
    // While the screen is on, Swift waits for a television's list that may still be coming.
    DisposableEffect(Unit) {
        RecBridge.recordingsShown(true)
        onDispose { RecBridge.recordingsShown(false) }
    }
    LaunchedEffect(shown.outdatedKey) { RecBridge.act { it.recordings.loadOutdated() } }
    var opened by remember { mutableStateOf<RecordingItem?>(null) }
    opened?.let { row -> TitleSheetView(row) { opened = null } }
    var pulling by remember { mutableStateOf(false) }
    Scaffold(topBar = {
        Column {
            TopAppBar(title = { TitleWithSubtitle(shown.heading, if (shown.hasNoRecorder || shown.isLoading) "" else shown.subtitle) },
                      actions = { Filters(shown) })
            StripBar()
        }
    }, bottomBar = {
        Column {
            // Under a list that is drawn, as on iOS: not while it is being read, nor with no recorder.
            if (shown.tvNote.isNotEmpty() && !shown.hasNoRecorder && !shown.isLoading) Line(shown.tvNote, false)
            Line(shown.line, shown.lineIsAProblem)
        }
    }) { padding ->
        Box(Modifier.padding(padding)) {
            when {
                shown.hasNoRecorder -> NoRecorderView(Icons.Outlined.VideoLibrary, shown.noRecorder, search)
                shown.isLoading -> Unavailable(Icons.Outlined.VideoLibrary, shown.loadingTitle, shown.loadingDetail)
                else -> PullToRefreshBox(isRefreshing = pulling, onRefresh = {
                    pulling = true
                    scope.launch {
                        try {
                            RecBridge.act { it.recordings.pullDown() }
                        } finally {
                            pulling = false
                        }
                    }
                }, modifier = Modifier.fillMaxSize()) {
                    // The empty state is the list's one item, so that an empty list can be pulled down as well.
                    LazyColumn(Modifier.fillMaxSize()) {
                        if (shown.rows.isEmpty()) {
                            item { Box(Modifier.fillParentMaxSize()) { Unavailable(Icons.Outlined.VideoLibrary, shown.emptyTitle, shown.emptyDetail) } }
                        }
                        items(shown.rows, key = { it.id }) { row -> RecordingRow(row) { opened = row } }
                    }
                }
            }
        }
    }
}

/** The menu of what the recordings are narrowed and sorted by, its icon filled while any is not its default. */
@Composable
private fun Filters(shown: Recordings) {
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(if (shown.filtering) Icons.Filled.FilterAlt else Icons.Outlined.FilterAlt,
                 contentDescription = if (shown.destinations.isEmpty()) "ジャンル・並び順・視聴状態で絞り込む"
                                      else "録画先・ジャンル・並び順・視聴状態で絞り込む")
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            val group = @Composable { heading: String, options: List<Labelled>, chosen: String, pick: suspend (String) -> Unit ->
                Text(heading, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
                     modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
                for (option in options) {
                    DropdownMenuItem(text = { Text(option.label) }, onClick = {
                        open = false
                        scope.launch { pick(option.code) }
                    }, leadingIcon = {
                        if (option.code == chosen) Icon(Icons.Default.Check, contentDescription = null)
                        else Spacer(Modifier.size(24.dp))
                    })
                }
            }
            if (shown.destinations.isNotEmpty()) {
                group("録画先", shown.destinations, shown.destination) { code -> RecBridge.act { it.recordings.chooseDestination(code) } }
                HorizontalDivider()
            }
            group("ジャンル", shown.genres, shown.genre) { code -> RecBridge.act { it.recordings.chooseGenre(code) } }
            HorizontalDivider()
            group("並び順", shown.sorts, shown.sort) { code -> RecBridge.act { it.recordings.chooseSort(code) } }
            HorizontalDivider()
            group("視聴状態", shown.states, shown.state) { code -> RecBridge.act { it.recordings.chooseState(code) } }
        }
    }
}

/** One recording, as the iOS row says it: the lock and 録画中 before the title, then when, where and how, then whether it was watched. */
@Composable
internal fun RecordingRow(item: RecordingItem, open: () -> Unit) {
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
        modifier = Modifier.clickable(onClick = open),
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
