package jp.hiroaki.bdbridge

import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun RecBridgeTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= 31 && dark -> dynamicDarkColorScheme(context)
        Build.VERSION.SDK_INT >= 31 -> dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}

/** The orange the iOS app marks a reservation with. */
private val reservedOrange = Color(0xFFE07000)

/**
 * The app: where a recorder is chosen, over the guide, the reservations and the recordings. The place to choose opens
 * by itself while nothing is set up, as the iOS app's tutorial does, and closes once a recorder chosen there answers.
 */
@Composable
fun App() {
    val devices by RecBridge.devices.collectAsState()
    val shown = devices ?: return Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
    // Open at first while nothing is set up, as the app starts, then as the reader opens and closes it: decided once,
    // as the iOS app decides it, so that leaving the demo started with does not open it.
    var choosing by rememberSaveable { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(Unit) { if (choosing == null) choosing = shown.welcomes }
    val scope = rememberCoroutineScope()
    val close = {
        choosing = false
        scope.launch { RecBridge.act { it.devices.closed() } }
        Unit
    }
    LaunchedEffect(shown.chosenAnswered) { if (shown.chosenAnswered) close() }
    if (choosing ?: shown.welcomes) DevicesScreen(shown, close) else RecorderScreen(shown) { choosing = true }
}

/** Where a recorder is chosen, as the iOS app's tutorial chooses one: the search, an address, or the demo. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(shown: Devices, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    var typing by rememberSaveable { mutableStateOf(false) }
    var address by rememberSaveable { mutableStateOf("") }
    var typed by remember { mutableStateOf(Typed("", false, "", false)) }
    LaunchedEffect(address) { typed = RecBridge.typed(address) }
    BackHandler(onBack = close)
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("レコーダーを探す") },
            navigationIcon = {
                TextButton(onClick = close) { Text(if (shown.welcomes) "あとで設定" else "閉じる") }
            },
        )
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp),
                   verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                Button(onClick = { scope.launch { RecBridge.act { it.devices.search() } } },
                       enabled = !shown.searching && shown.busy.isEmpty(), modifier = Modifier.fillMaxWidth()) {
                    Text("レコーダーとテレビを探す")
                }
            }
            if (shown.toSearch > 0) item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    LinearProgressIndicator(progress = { shown.searched.toFloat() / shown.toSearch }, Modifier.fillMaxWidth())
                    Text("検索中 ${shown.searched} / ${shown.toSearch}", style = MaterialTheme.typography.bodySmall)
                }
            }
            if (shown.outcome.isNotEmpty()) item { Outcome(shown) }
            if (shown.busy.isNotEmpty()) item {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.width(16.dp), strokeWidth = 2.dp)
                    Text(shown.busy)
                }
            }
            if (shown.problem.isNotEmpty()) item { Text(shown.problem, color = MaterialTheme.colorScheme.error) }
            if (shown.recorders.isNotEmpty()) {
                item { Heading("見つかったレコーダー") }
                items(shown.recorders, key = { it.host }) { found ->
                    ListItem(
                        headlineContent = { Text(found.name) },
                        supportingContent = { Text(found.details) },
                        trailingContent = { Text(if (found.inUse) "使用中" else "接続する", color = MaterialTheme.colorScheme.primary) },
                        modifier = Modifier.clickable(enabled = shown.canChoose) {
                            scope.launch { RecBridge.act { it.devices.choose(found.host) } }
                        },
                    )
                }
            }
            item {
                if (typing) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(value = address, onValueChange = { address = it }, singleLine = true,
                                          label = { Text("192.168.1.10") }, modifier = Modifier.fillMaxWidth())
                        if (typed.note.isNotEmpty()) {
                            Text(typed.note, style = MaterialTheme.typography.bodySmall,
                                 color = if (typed.warning) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        TextButton(onClick = {
                            address = typed.host
                            scope.launch { RecBridge.act { it.devices.choose(typed.host) } }
                        }, enabled = typed.usable && shown.canChoose) { Text("このアドレスに接続") }
                    }
                } else {
                    TextButton(onClick = { typing = true }) { Text("IP アドレスを直接入力") }
                }
                Footnote("見つからない場合は、レコーダーの設定画面で確認できる IP アドレスを直接入力できます。")
            }
            item {
                TextButton(onClick = {
                    scope.launch {
                        RecBridge.act { it.devices.enterDemo() }
                        close()
                    }
                }, enabled = shown.canChoose) { Text("サンプルデータで試す") }
                Footnote("レコーダーが無くても、架空の番組表と録画一覧でアプリの動きを確かめられます。"
                         + "実在の放送局・番組ではありません。")
            }
        }
    }
}

@Composable
private fun Outcome(shown: Devices) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(shown.outcome, color = if (shown.outcomeFailed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        if (shown.outcomeNote.isNotEmpty()) Footnote(shown.outcomeNote)
        if (shown.causes.isNotEmpty()) {
            Text("考えられる原因", style = MaterialTheme.typography.labelMedium)
            for (cause in shown.causes) Footnote("・$cause")
        }
    }
}

@Composable
private fun Heading(text: String) {
    Text(text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun Footnote(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** The guide, the reservations and the recordings, under the demo's line when it is on. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecorderScreen(devices: Devices, search: () -> Unit) {
    val scope = rememberCoroutineScope()
    var tab by rememberSaveable { mutableIntStateOf(0) }
    Scaffold(topBar = {
        TopAppBar(
            title = {
                Column {
                    Text("RecBridge")
                    // The demo is said apart, so that its invented rows are never taken for a real recorder's.
                    if (devices.demo) Text("デモ", style = MaterialTheme.typography.labelMedium)
                }
            },
            actions = {
                if (devices.demo) {
                    IconButton(onClick = { scope.launch { RecBridge.act { it.devices.leaveDemo() } } },
                               enabled = devices.canChoose) {
                        Icon(Icons.AutoMirrored.Filled.ExitToApp, contentDescription = "デモを終了")
                    }
                } else {
                    IconButton(onClick = search) { Icon(Icons.Default.Search, contentDescription = "レコーダーを探す") }
                }
            },
        )
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            TabRow(selectedTabIndex = tab) {
                Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("番組表") })
                Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("予約") })
                Tab(selected = tab == 2, onClick = { tab = 2 }, text = { Text("録画") })
            }
            when (tab) {
                0 -> GuideTab(search)
                1 -> ReservationsTab(search)
                else -> RecordingsTab(search)
            }
        }
    }
}

/** What a screen says in place of its list with no recorder to talk to (`NoRecorderView`). */
@Composable
private fun NoRecorderView(said: NoRecorder, search: () -> Unit) {
    val scope = rememberCoroutineScope()
    Unavailable(said.title, said.detail) {
        when (said.kind) {
            "notAdded" -> Button(onClick = search) { Text("レコーダーを探す") }
            "working" -> CircularProgressIndicator()
            "notReached" -> {
                Button(onClick = { scope.launch { RecBridge.act { it.app.connect() } } }) { Text("再接続") }
                TextButton(onClick = search) { Text("レコーダーを探す") }
            }
        }
    }
}

/** A title, what is said under it and what is offered, in the middle of the screen. */
@Composable
private fun Unavailable(title: String, detail: String, actions: @Composable () -> Unit = {}) {
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
           horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        if (detail.isNotEmpty()) {
            Text(detail, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
                 color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        actions()
    }
}

/** The minute it is now, in seconds since 1970, turning over each minute so that what is on air is marked as it starts. */
@Composable
private fun minuteNow(): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis() / 1000) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(60_000 - System.currentTimeMillis() % 60_000)
            now = System.currentTimeMillis() / 1000
        }
    }
    return now
}

/** One broadcasting type's broadcast day, every station or one, as the iOS guide's list shows it. */
@Composable
private fun GuideTab(search: () -> Unit) {
    val guide = RecBridge.guide.collectAsState().value ?: return
    val scope = rememberCoroutineScope()
    var opened by remember { mutableStateOf<ProgrammeSheet?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    opened?.let { ProgrammeSheetView(it) { opened = null } }
    failure?.let { said ->
        AlertDialog(onDismissRequest = { failure = null }, confirmButton = { TextButton(onClick = { failure = null }) { Text("OK") } },
                    title = { Text("番組表を取得できませんでした") }, text = { Text(said) })
    }
    Column(Modifier.fillMaxSize()) {
        LazyRow(contentPadding = PaddingValues(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            items(guide.broadcastings, key = { it.code }) { choice ->
                FilterChip(selected = guide.broadcasting == choice.code, label = { Text(choice.label) },
                           onClick = { scope.launch { RecBridge.act { it.guide.chooseBroadcasting(choice.code) } } })
            }
        }
        if (guide.stations.isNotEmpty()) {
            LazyRow(contentPadding = PaddingValues(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                item {
                    FilterChip(selected = guide.station < 0, label = { Text("すべての局") },
                               onClick = { scope.launch { RecBridge.act { it.guide.chooseStation(-1) } } })
                }
                items(guide.stations, key = { it.serviceID }) { station ->
                    FilterChip(selected = guide.station == station.serviceID, label = { Text(station.name, maxLines = 1) },
                               onClick = { scope.launch { RecBridge.act { it.guide.chooseStation(station.serviceID) } } })
                }
            }
        }
        Row(Modifier.padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { scope.launch { RecBridge.act { it.guide.chooseDay((guide.day - 1).toLong()) } } },
                       enabled = guide.day > 0) { Text("前の日") }
            DayMenu(guide, Modifier.weight(1f))
            TextButton(onClick = { scope.launch { RecBridge.act { it.guide.chooseDay((guide.day + 1).toLong()) } } },
                       enabled = guide.day < guide.days.size - 1) { Text("次の日") }
            IconButton(onClick = {
                refreshing = true
                scope.launch {
                    val said = RecBridge.ask { it.guide.refreshByHand() }
                    refreshing = false
                    if (said.isNotEmpty()) failure = said
                }
            }, enabled = guide.canRefresh && !refreshing) {
                Icon(Icons.Default.Refresh, contentDescription = "番組表を更新")
            }
        }
        when (guide.shows) {
            "noRecorder" -> NoRecorderView(guide.noRecorder, search)
            "fetching" -> Unavailable(guide.title, guide.detail) { CircularProgressIndicator() }
            "empty" -> Unavailable(guide.title, guide.detail) {
                if (guide.offers == "everyStation") {
                    TextButton(onClick = { scope.launch { RecBridge.act { it.guide.chooseStation(-1) } } }) {
                        Text("すべての局を表示")
                    }
                }
            }
            else -> Programmes(guide) { id -> scope.launch { opened = programmeSheet(id) } }
        }
    }
}

/** The day, which opens the days and 今, as the iOS guide's does. */
@Composable
private fun DayMenu(guide: Guide, modifier: Modifier) {
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    Box(modifier, contentAlignment = Alignment.Center) {
        TextButton(onClick = { open = true }) {
            Text(guide.days.getOrElse(guide.day) { "" }, style = MaterialTheme.typography.titleSmall)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text("今") }, onClick = {
                open = false
                scope.launch { RecBridge.act { it.guide.goToNow() } }
            })
            HorizontalDivider()
            guide.days.forEachIndexed { index, day ->
                DropdownMenuItem(text = { Text(day) }, onClick = {
                    open = false
                    scope.launch { RecBridge.act { it.guide.chooseDay(index.toLong()) } }
                })
            }
        }
    }
}

/**
 * The day's programmes. The list opens at what is on now, or on another day at its first, as the iOS list does, and
 * goes back there each time 今 is asked for.
 */
@Composable
private fun Programmes(guide: Guide, open: (String) -> Unit) {
    val now = minuteNow()
    val opening = guide.programmes.indexOfFirst { it.ends > now }.coerceAtLeast(0)
    // Made again for each list, so that a new one opens at its own place: by the programmes themselves, since the
    // day or the type changes first and the programmes read for it come after (on iOS, the guide's reads are waited
    // for, `guideReads`).
    val listed = with(guide.programmes) { "${size}-${firstOrNull()?.id}-${lastOrNull()?.id}" }
    val position = remember(listed) { androidx.compose.foundation.lazy.LazyListState(firstVisibleItemIndex = opening) }
    var answered by remember { mutableLongStateOf(guide.nowRequests) }
    LaunchedEffect(guide.nowRequests) {
        if (guide.nowRequests != answered) {
            answered = guide.nowRequests
            position.scrollToItem(opening)
        }
    }
    LazyColumn(Modifier.fillMaxSize(), state = position) {
        items(guide.programmes, key = { it.id }) { programme ->
            ProgrammeRowView(programme, now) { open(programme.id) }
            HorizontalDivider()
        }
    }
}

@Composable
private fun ProgrammeRowView(item: Programme, now: Long, open: () -> Unit) {
    val onAir = item.starts <= now && now < item.ends
    val ended = item.ends <= now
    Row(Modifier.fillMaxWidth().clickable(onClick = open).alpha(if (ended) 0.5f else 1f).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(Modifier.width(48.dp), horizontalAlignment = Alignment.End) {
            Text(item.time, style = MaterialTheme.typography.bodyMedium)
            Text(item.length, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis,
                 fontWeight = if (onAir) FontWeight.SemiBold else FontWeight.Normal)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val small = MaterialTheme.typography.labelSmall
                Text(item.station, style = small, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (onAir) Text("放送中", style = small, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
                if (item.mark.isNotEmpty()) Text(item.mark, style = small, color = if (item.markIsRed) Color.Red else reservedOrange)
                if (item.genre.isNotEmpty()) Text(item.genre, style = small, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (item.summary.isNotEmpty()) {
                Text(item.summary, style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** What the iOS app's programme sheet says of a programme, before its reservation part: read only here. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProgrammeSheetView(item: ProgrammeSheet, close: () -> Unit) {
    ModalBottomSheet(onDismissRequest = close) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp)
            .padding(bottom = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(item.title, style = MaterialTheme.typography.titleMedium)
            Labeled("放送", item.station)
            Labeled("開始", item.starts)
            Labeled("長さ", item.length)
            if (item.genre.isNotEmpty()) Labeled("ジャンル", item.genre)
            if (item.summary.isNotEmpty()) Part("番組内容", item.summary)
            if (item.extended.isNotEmpty()) Part("詳細", item.extended)
        }
    }
}

@Composable
private fun Labeled(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
        Text(value)
    }
}

@Composable
private fun Part(heading: String, body: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Heading(heading)
        Text(body, style = MaterialTheme.typography.bodyMedium)
    }
}

/** The recorder's line while it works, or what went wrong, at the foot of a list. */
@Composable
private fun Line(line: String, problem: Boolean) {
    if (line.isEmpty()) return
    Text(line, color = if (problem) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
         style = MaterialTheme.typography.bodyMedium, modifier = Modifier.fillMaxWidth().padding(12.dp))
}

/** The reservations, waiting ones first, then by day, as the iOS list shows them; read only here. */
@Composable
private fun ReservationsTab(search: () -> Unit) {
    val shown = RecBridge.reservations.collectAsState().value ?: return
    LaunchedEffect(shown.loadKey) { RecBridge.act { it.reservations.load() } }
    if (shown.hasNoRecorder) return NoRecorderView(shown.noRecorder, search)
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f)) {
            LazyColumn(Modifier.fillMaxSize()) {
                item { Text(shown.subtitle, style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(16.dp, 8.dp)) }
                if (shown.waiting.isNotEmpty()) {
                    sectionHeading("送信待ち ${shown.waiting.size} 件")
                    items(shown.waiting, key = { "waiting-" + it.id }) { waiting ->
                        ListItem(
                            headlineContent = { Text(waiting.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                            supportingContent = {
                                Column {
                                    Text(waiting.details)
                                    if (waiting.problem.isNotEmpty()) Text(waiting.problem, color = MaterialTheme.colorScheme.error)
                                }
                            },
                        )
                    }
                }
                for (section in shown.sections) {
                    sectionHeading(section.title)
                    items(section.rows, key = { it.id }) { row -> ReservationRowView(row) }
                }
            }
            if (shown.isEmpty) Unavailable(shown.emptyTitle, shown.emptyDetail)
        }
        Line(shown.line, shown.lineIsAProblem)
    }
}

private fun LazyListScope.sectionHeading(title: String) {
    item(key = "heading-$title") {
        Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
             modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp))
    }
}

@Composable
private fun ReservationRowView(item: ReservationItem) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(item.time, style = MaterialTheme.typography.bodySmall)
            Text(item.length, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (item.recording) Text("録画中", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = Color.Red)
            if (item.conflict) Text("重複", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = reservedOrange)
            if (item.byTheRecorder) Text("おまかせ", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(item.details, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    HorizontalDivider()
}

/** The recordings, newest first, as the iOS list shows them; read only here. */
@Composable
private fun RecordingsTab(search: () -> Unit) {
    val shown = RecBridge.recordings.collectAsState().value ?: return
    LaunchedEffect(shown.loadKey) { RecBridge.act { it.recordings.load() } }
    when {
        shown.hasNoRecorder -> return NoRecorderView(shown.noRecorder, search)
        shown.isLoading -> return Unavailable(shown.loadingTitle, shown.loadingDetail)
    }
    Column(Modifier.fillMaxSize()) {
        Text("${shown.heading} · ${shown.subtitle}", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(16.dp, 8.dp))
        Box(Modifier.weight(1f)) {
            LazyColumn(Modifier.fillMaxSize(), state = rememberLazyListState()) {
                items(shown.rows, key = { it.id }) { row -> RecordingRowView(row) }
            }
            if (shown.rows.isEmpty()) Unavailable(shown.emptyTitle, shown.emptyDetail)
        }
        Line(shown.line, shown.lineIsAProblem)
    }
}

@Composable
private fun RecordingRowView(item: RecordingItem) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            if (item.protected) Text("保護", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (item.recording) Text("録画中", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = Color.Red)
            Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Text(item.details, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(item.watched, style = MaterialTheme.typography.labelSmall,
                 color = if (item.unwatched) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            if (item.genre.isNotEmpty()) Text(item.genre, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    HorizontalDivider()
}
