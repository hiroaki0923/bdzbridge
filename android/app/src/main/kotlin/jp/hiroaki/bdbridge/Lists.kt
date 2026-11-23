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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.VideoLibrary
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
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

// The reservations and the recordings as the iOS lists show them, over the model's states of the two screens.

/**
 * The reservations, the ones waiting on this device first, then under headings that stay as the list scrolls: the
 * day, or the genre or the station when the menu sorts by them. A row swiped to the left asks to delete it; a waiting
 * row a device refused, swiped to the right, is sent again. Pulled down, what waits is sent and both devices' lists
 * are read again. What is asked, held and said is the model's (`ReservationsState`).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ReservationsScreen(search: () -> Unit, openConditions: () -> Unit) {
    val shown = RecBridge.reservations.collectAsState().value ?: return
    val scope = rememberCoroutineScope()
    val colors = MaterialTheme.colorScheme
    val words = RecBridge.listWords
    LaunchedEffect(shown.loadKey) { RecBridge.act { it.reservations.load() } }
    LaunchedEffect(Unit) { RecBridge.act { it.reservations.loadTV() } }
    // What is said of a list that is old, read again each minute, as the iOS heading turns over.
    val minute = minuteNow()
    var stale by remember { mutableStateOf(emptyList<String>()) }
    LaunchedEffect(shown.staleKey, minute) {
        stale = if (shown.staleKey.isEmpty()) emptyList()
                else RecBridge.ask { it.reservations.stale() }.lines().filter { it.isNotEmpty() }
    }
    val wide = twoPanes()
    // The reservation whose sheet is open, or that is open beside the list.
    var opened by remember { mutableStateOf<ReservationItem?>(null) }
    // Its window, opened here and handed to the sheet or the pane, whichever shows it (`rememberOpened`).
    val reservation = opened?.let { row -> row to rememberOpened(row.id) { RecBridge.openReservation(row.id) } }
    if (!wide) reservation?.let { (row, window) -> ReservationSheetView(row.title, window) { opened = null } }
    // Not while the one open beside the list is held: it would take the request's answer with it.
    val open = { row: ReservationItem -> if (!PaneHold.held) opened = row }
    shown.asked?.let { asked ->
        AskDialog(asked, act = { scope.launch { RecBridge.act { it.reservations.act(asked.key) } } },
                  closeAsked = { scope.launch { RecBridge.act { it.reservations.closeAsked(asked.key) } } })
    }
    val delete = { label: String, held: Boolean, ask: suspend () -> Unit ->
        SwipeAction(label, colors.errorContainer, colors.onErrorContainer, !held) { scope.launch { ask() } }
    }
    var pulling by remember { mutableStateOf(false) }
    val logos = rememberLogos(shown.logos)
    Scaffold(topBar = { Refused {
        Column {
            TopAppBar(title = { TitleWithSubtitle(words.reservationsTitle, if (shown.hasNoRecorder) "" else shown.subtitle) },
                      actions = {
                          KindAndSort(shown)
                          // The recorder's own keyword conditions, which only a connected recorder can be asked for.
                          IconButton(onClick = openConditions, enabled = !shown.conditionsHeld) {
                              Icon(Icons.Outlined.AutoAwesome, contentDescription = words.conditionsLabel)
                          }
                      })
            StripBar()
        }
    } }, bottomBar = { Line(shown.line, shown.lineIsAProblem) }) { padding ->
        Box(Modifier.padding(padding)) {
            ListAndDetail(opened != null, close = { opened = null },
                          nothingOpened = {
                              if (!shown.hasNoRecorder && !shown.isEmpty) {
                                  NothingOpened(Icons.Outlined.Schedule, NothingOpenedSays.reservation)
                              }
                          },
                          detail = {
                              reservation?.let { (row, window) ->
                                  // By the reservation, so that nothing of one carries to the next.
                                  key(row.id) {
                                      ReservationSheetView(row.title, window, inPane = true,
                                                           listed = shown.lists(row.id)) { opened = null }
                                  }
                              }
                          }) {
                if (shown.hasNoRecorder) {
                    return@ListAndDetail NoRecorderView(Icons.Outlined.Schedule, shown.noRecorder, search)
                }
                PullToRefreshBox(isRefreshing = pulling, onRefresh = {
                    pulling = true
                    scope.launch {
                        try {
                            RecBridge.act { it.reservations.pullDown() }
                        } finally {
                            pulling = false
                        }
                    }
                }, modifier = Modifier.fillMaxSize()) {
                    // The empty state is the list's one item, so that an empty list can be pulled down as well.
                    LazyColumn(Modifier.fillMaxSize()) {
                        if (shown.isEmpty) {
                            item { Box(Modifier.fillParentMaxSize()) { Unavailable(Icons.Outlined.Schedule, shown.emptyTitle, shown.emptyDetail) } }
                        }
                        items(stale, key = { "stale-$it" }) { line -> Footnote(line, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
                        if (shown.waiting.isNotEmpty()) {
                            heading(shown.waitingHeading)
                            items(shown.waiting, key = { "waiting-" + it.id }) { waiting ->
                                val again = if (!waiting.offersSendingAgain) null else
                                    SwipeAction(words.sendAgainLabel, colors.primaryContainer, colors.onPrimaryContainer, !waiting.held) {
                                        scope.launch { RecBridge.act { it.reservations.sendAgain(waiting.id) } }
                                    }
                                SwipeActions(toTheRight = again, toTheLeft = delete(words.deleteLabel, waiting.held) {
                                    RecBridge.act { it.reservations.deleteWaiting(waiting.id) }
                                }) { WaitingRow(waiting) }
                            }
                            if (shown.waitingSays.isNotEmpty()) {
                                item(key = "waiting-says") { Footnote(shown.waitingSays, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
                            }
                        }
                        for (section in shown.sections) {
                            heading(section.title)
                            items(section.rows, key = { it.id }) { row ->
                                SwipeActions(toTheRight = null, toTheLeft = delete(words.deleteLabel, row.deleteHeld) {
                                    RecBridge.act { it.reservations.delete(row.id) }
                                }) {
                                    ReservationRow(row, logos[row.logo], current = wide && row.id == opened?.id) {
                                        open(row)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Whether the list under its headings has the reservation with `id`. */
private fun Reservations.lists(id: String): Boolean =
    !hasNoRecorder && sections.any { section -> section.rows.any { it.id == id } }

/** The menu of which kind of reservation is listed and what the list is sorted by, its icon filled while either is not its default. */
@Composable
private fun KindAndSort(shown: Reservations) {
    val scope = rememberCoroutineScope()
    val words = RecBridge.listWords
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(if (shown.filtering) Icons.Filled.FilterAlt else Icons.Outlined.FilterAlt, contentDescription = words.menuLabel)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            MenuGroup(words.kindHeading, shown.kinds, shown.kind) { code ->
                open = false
                scope.launch { RecBridge.act { it.reservations.chooseKind(code) } }
            }
            HorizontalDivider()
            MenuGroup(words.sortHeading, shown.sorts, shown.sort) { code ->
                open = false
                scope.launch { RecBridge.act { it.reservations.chooseSort(code) } }
            }
        }
    }
}

/** A menu's choices under their heading, the one chosen ticked. */
@Composable
private fun MenuGroup(heading: String, options: List<Labelled>, chosen: String, pick: (String) -> Unit) {
    Text(heading, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
         modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
    for (option in options) {
        DropdownMenuItem(text = { Text(option.label) }, onClick = { pick(option.code) }, leadingIcon = {
            if (option.code == chosen) Icon(Icons.Default.Check, contentDescription = null)
            else Spacer(Modifier.size(24.dp))
        })
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

/**
 * One reservation, as the iOS row says it: when and how long, marked, the title, then the station and how it records.
 * `current` when it is the one open beside the list.
 */
@Composable
internal fun ReservationRow(item: ReservationItem, logo: ImageBitmap?, current: Boolean = false, open: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val marks = LocalMarks.current
    ListItem(
        overlineContent = {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("${item.time} · ${item.length}")
                if (item.recording) Mark(RecBridge.listWords.recordingMark, colors.errorContainer, colors.onErrorContainer)
                if (item.conflict) Mark(RecBridge.listWords.conflictMark, marks.reserved, marks.onReserved)
                if (item.byTheRecorder) Mark(RecBridge.listWords.recorderMadeMark, colors.surfaceContainerHighest, colors.onSurfaceVariant)
            }
        },
        headlineContent = { Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        // The logo's space is held where a station has none, so that the names line up down the list.
        supportingContent = { LogoLine("", logo, item.details, holdSpace = true) },
        colors = openedColors(current),
        modifier = Modifier.clickable(onClick = open).saidOpened(current),
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
 * The recordings, with the free space in the top app bar, the three views of them before it -- 一覧, まとめ and 重複 --
 * and the iOS screen's menu after it: 録画先, ジャンル, 並び順 and 視聴状態. Pulled down, the list is read again from
 * both devices. A row swiped to the left asks to delete it, or takes the protection off a protected one. A programme
 * of まとめ opens its page over the screen. What is asked, held and said is the model's (`RecordingsState`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordingsScreen(search: () -> Unit, openGroup: (GroupItem) -> Unit) {
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
    val wide = twoPanes()
    // The recording whose sheet is open, or that is open beside the list, and its window, opened here and handed to
    // the sheet or the pane, whichever shows it (`rememberOpened`).
    var opened by remember { mutableStateOf<RecordingItem?>(null) }
    val recording = opened?.let { row -> row to rememberOpened(row.id) { RecBridge.openRecording(row.id) } }
    if (!wide) recording?.let { (row, window) -> TitleSheetView(row, window) { opened = null } }
    val logos = rememberLogos(shown.logos)
    // A copy among the duplicates, whose sheet is opened from its set, and its window, the same way.
    var openedCopy by remember { mutableStateOf<RecordingItem?>(null) }
    val copy = openedCopy?.let { row -> row to rememberOpened(row.id) { RecBridge.openCopy(row.id) } }
    if (!wide) copy?.let { (row, window) -> TitleSheetView(row, window) { openedCopy = null } }
    // Beside the list one at a time, a recording of 一覧 or a copy of 重複, and not while that one is held: it would
    // take the request's answer with it.
    val open = { row: RecordingItem ->
        if (!PaneHold.held) {
            opened = row
            openedCopy = null
        }
    }
    val openCopy = { row: RecordingItem ->
        if (!PaneHold.held) {
            openedCopy = row
            opened = null
        }
    }
    // まとめ has no pane, its programmes opening a page over the whole: what was open beside 一覧 or 重複 goes as the
    // view turns to it, which is not while it is held.
    LaunchedEffect(wide, shown.mode) {
        if (wide && shown.mode == "groups") {
            opened = null
            openedCopy = null
        }
    }
    val duplicates = RecBridge.duplicates.collectAsState().value
    shown.asked?.let { asked ->
        AskDialog(asked, act = { scope.launch { RecBridge.act { it.recordings.act(asked.key) } } },
                  closeAsked = { scope.launch { RecBridge.act { it.recordings.closeAsked(asked.key) } } },
                  actionEnabled = !shown.actionHeld)
    }
    var pulling by remember { mutableStateOf(false) }
    val pulled = @Composable { content: @Composable () -> Unit ->
        PullToRefreshBox(isRefreshing = pulling, onRefresh = {
            pulling = true
            scope.launch {
                try {
                    RecBridge.act { it.recordings.pullDown() }
                } finally {
                    pulling = false
                }
            }
        }, modifier = Modifier.fillMaxSize()) { content() }
    }
    Box(Modifier.fillMaxSize()) {
        Scaffold(topBar = { Refused {
            Column {
                TopAppBar(title = { TitleWithSubtitle(shown.heading, if (shown.hasNoRecorder || shown.isLoading) "" else shown.subtitle) },
                          navigationIcon = { Views(shown) }, actions = { Filters(shown) })
                StripBar()
                JobBarView()
            }
        } }, bottomBar = {
            // Under a list that is drawn, as on iOS: not while it is being read, with no recorder, or over the
            // duplicates.
            if (shown.tvNote.isNotEmpty() && !shown.hasNoRecorder && !shown.isLoading && shown.mode != "dups") Line(shown.tvNote, false)
        }) { padding ->
            Box(Modifier.padding(padding)) {
                // The empty state is the list's one item, so that an empty list can be pulled down as well.
                val empty = @Composable { Unavailable(Icons.Outlined.VideoLibrary, shown.emptyTitle, shown.emptyDetail) }
                val anything = !shown.hasNoRecorder && !shown.isLoading &&
                    (if (shown.mode == "dups") duplicates?.hasSets == true else shown.rows.isNotEmpty())
                ListAndDetail(opened != null || openedCopy != null,
                              close = {
                                  opened = null
                                  openedCopy = null
                              },
                              nothingOpened = {
                                  if (anything) NothingOpened(Icons.Outlined.VideoLibrary, NothingOpenedSays.recording)
                              },
                              detail = {
                                  // By the recording, so that nothing of one carries to the next.
                                  recording?.let { (row, window) ->
                                      key(row.id) {
                                          TitleSheetView(row, window, inPane = true, listed = shown.lists(row.id)) {
                                              opened = null
                                          }
                                      }
                                  }
                                  copy?.let { (row, window) ->
                                      key("copy-" + row.id) {
                                          TitleSheetView(row, window, inPane = true,
                                                         listed = shown.mode == "dups" && duplicates.lists(row.id)) {
                                              openedCopy = null
                                          }
                                      }
                                  }
                              },
                              // まとめ's programmes open a page over the whole, not the pane: the list has the width.
                              beside = shown.mode != "groups") {
                    when {
                        shown.hasNoRecorder -> NoRecorderView(Icons.Outlined.VideoLibrary, shown.noRecorder, search)
                        shown.isLoading -> Unavailable(Icons.Outlined.VideoLibrary, shown.loadingTitle, shown.loadingDetail)
                        shown.mode == "dups" -> {
                            DuplicatesView(pulled, current = if (wide) openedCopy?.id else null, open = openCopy)
                        }
                        shown.mode == "groups" -> pulled {
                            LazyColumn(Modifier.fillMaxSize()) {
                                if (shown.groups.isEmpty()) item { Box(Modifier.fillParentMaxSize()) { empty() } }
                                items(shown.groups, key = { it.id }) { programme -> GroupRowView(programme) { openGroup(programme) } }
                            }
                        }
                        else -> pulled {
                            LazyColumn(Modifier.fillMaxSize()) {
                                if (shown.rows.isEmpty()) item { Box(Modifier.fillParentMaxSize()) { empty() } }
                                items(shown.rows, key = { it.id }) { row ->
                                    RecordingSwipes(row, delete = { scope.launch { RecBridge.act { it.recordings.delete(row.id) } } },
                                                    unprotect = { scope.launch { RecBridge.act { it.recordings.unprotect(row.id) } } }) {
                                        val current = wide && row.id == opened?.id
                                        RecordingRow(row, logo = logos[row.logo], current = current) { open(row) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Whether 一覧, as it is narrowed and with a recorder to list, has the recording with `id`. */
private fun Recordings.lists(id: String): Boolean =
    mode == "list" && !hasNoRecorder && !isLoading && rows.any { it.id == id }

/** Whether the duplicates' sets have the copy with `id`. */
private fun Duplicates?.lists(id: String): Boolean =
    this != null && hasSets && sets.any { set -> set.copies.any { it.id == id } }

/** 一覧, まとめ and 重複: the menu of the three views, under the icon of the one that is on. */
@Composable
private fun Views(shown: Recordings) {
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    val icon = { mode: String ->
        when (mode) {
            "groups" -> Icons.Outlined.Layers
            "dups" -> Icons.Outlined.ContentCopy
            else -> Icons.AutoMirrored.Filled.List
        }
    }
    Box {
        IconButton(onClick = { open = true }) { Icon(icon(shown.mode), contentDescription = RecBridge.listWords.viewMenuLabel) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for (mode in shown.modes) {
                DropdownMenuItem(text = { Text(mode.label) }, leadingIcon = { Icon(icon(mode.code), contentDescription = null) },
                                 trailingIcon = { if (mode.code == shown.mode) Icon(Icons.Default.Check, contentDescription = null) },
                                 onClick = {
                                     open = false
                                     scope.launch { RecBridge.act { it.recordings.chooseMode(mode.code) } }
                                 })
            }
        }
    }
}

/** The menu of what the recordings are narrowed and sorted by, its icon filled while any is not its default. */
@Composable
private fun Filters(shown: Recordings) {
    val scope = rememberCoroutineScope()
    val words = RecBridge.listWords
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(if (shown.filtering) Icons.Filled.FilterAlt else Icons.Outlined.FilterAlt,
                 contentDescription = shown.filterMenuLabel)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            val group = @Composable { heading: String, options: List<Labelled>, chosen: String, pick: suspend (String) -> Unit ->
                MenuGroup(heading, options, chosen) { code ->
                    open = false
                    scope.launch { pick(code) }
                }
            }
            if (shown.destinations.isNotEmpty()) {
                group(words.destinationHeading, shown.destinations, shown.destination) { code -> RecBridge.act { it.recordings.chooseDestination(code) } }
                HorizontalDivider()
            }
            group(words.genreHeading, shown.genres, shown.genre) { code -> RecBridge.act { it.recordings.chooseGenre(code) } }
            HorizontalDivider()
            group(words.sortHeading, shown.sorts, shown.sort) { code -> RecBridge.act { it.recordings.chooseSort(code) } }
            HorizontalDivider()
            group(words.viewingHeading, shown.states, shown.state) { code -> RecBridge.act { it.recordings.chooseState(code) } }
        }
    }
}

/**
 * One recording, as the iOS row says it: the lock and 録画中 before the title, then when, where and how, then whether it
 * was watched. `current` when it is the one open beside the list.
 */
@Composable
internal fun RecordingRow(item: RecordingItem, selected: Boolean? = null, logo: ImageBitmap? = null,
                          current: Boolean = false, open: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    ListItem(
        headlineContent = {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                if (item.protected) Icon(Icons.Default.Lock, contentDescription = "保護", Modifier.size(14.dp), tint = colors.onSurfaceVariant)
                if (item.recording) Mark(RecBridge.listWords.recordingMark, colors.errorContainer, colors.onErrorContainer)
                Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                if (logo == null) Text(item.details) else {
                    val at = item.logoAt.coerceIn(0, item.details.length)
                    LogoLine(item.details.substring(0, at), logo, item.details.substring(at), holdSpace = false)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(item.watched, color = if (item.unwatched) colors.primary else colors.onSurfaceVariant)
                    // How far one watched partway was watched, as the iOS row's bar.
                    if (item.resume >= 0) LinearProgressIndicator(progress = { item.resume / 100f }, modifier = Modifier.width(60.dp))
                    if (item.genre.isNotEmpty()) Text(item.genre)
                }
            }
        },
        colors = openedColors(current),
        // On a programme's page while picking, the tick is said to a screen reader as the row being selected, on the
        // node it reads, rather than as the name of a circle.
        modifier = Modifier.clickable(onClick = open).then(
            if (selected == null) Modifier else Modifier.semantics { this.selected = selected }).saidOpened(current),
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
