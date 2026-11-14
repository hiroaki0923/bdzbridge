package jp.hiroaki.bdbridge

import android.graphics.BitmapFactory
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Today
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/**
 * The guide as the iOS guide's list shows it: one broadcasting type and one broadcast day, every station or one. The
 * top app bar holds what is shown -- the type and the station in its title, which opens a menu of both -- with 今 and
 * 番組表を更新; the day is under it, a step either side.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GuideScreen(search: () -> Unit, arrange: () -> Unit) {
    val guide = RecBridge.guide.collectAsState().value ?: return
    val scope = rememberCoroutineScope()
    // The programme whose sheet is open: shown at once with what its row says.
    var opened by remember { mutableStateOf<Programme?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    opened?.let { ProgrammeSheetView(it) { opened = null } }
    failure?.let { said ->
        AlertDialog(onDismissRequest = { failure = null },
                    confirmButton = { TextButton(onClick = { failure = null }) { Text("OK") } },
                    title = { Text("番組表を取得できませんでした") }, text = { Text(said) })
    }
    Scaffold(topBar = {
        Column {
            TopAppBar(
                title = { WhatIsShown(guide, arrange) },
                actions = {
                    IconButton(onClick = { scope.launch { RecBridge.act { it.guide.goToNow() } } }) {
                        Icon(Icons.Outlined.Today, contentDescription = "今")
                    }
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
                },
            )
            DayBar(guide)
            StripBar()
        }
    }) { padding ->
        Box(Modifier.padding(padding)) {
            when (guide.shows) {
                "noRecorder" -> NoRecorderView(Icons.Outlined.GridView, guide.noRecorder, search)
                "fetching" -> Unavailable(Icons.Outlined.GridView, guide.title, guide.detail) { CircularProgressIndicator() }
                "empty" -> Unavailable(if (guide.offers == "arrange") Icons.Outlined.VisibilityOff else Icons.Outlined.GridView,
                                       guide.title, guide.detail) {
                    if (guide.offers == "arrange") Button(onClick = arrange) { Text("チャンネルの表示と並び順") }
                    if (guide.offers == "everyStation") {
                        TextButton(onClick = { scope.launch { RecBridge.act { it.guide.chooseStation(-1) } } }) {
                            Text("すべての局を表示")
                        }
                    }
                }
                else -> Programmes(guide) { programme -> opened = programme }
            }
        }
    }
}

/** The type, or the station the list is narrowed to, as the top app bar's title: a menu of the types and the stations. */
@Composable
private fun WhatIsShown(guide: Guide, arrange: () -> Unit) {
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.clickable { open = true }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(guide.heading, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Icon(Icons.Default.ArrowDropDown, contentDescription = null)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for (choice in guide.broadcastings) {
                Choosable(choice.label, guide.broadcasting == choice.code) {
                    open = false
                    scope.launch { RecBridge.act { it.guide.chooseBroadcasting(choice.code) } }
                }
            }
            // Above the stations rather than after them, where a type with sixty would leave it at the foot of a long
            // menu, as on iOS.
            HorizontalDivider()
            DropdownMenuItem(text = { Text("チャンネルの表示と並び順") }, leadingIcon = { Icon(Icons.Default.SwapVert, contentDescription = null) },
                             onClick = {
                                 open = false
                                 arrange()
                             })
            if (guide.stations.isNotEmpty()) {
                HorizontalDivider()
                Choosable("すべての局", guide.station < 0) {
                    open = false
                    scope.launch { RecBridge.act { it.guide.chooseStation(-1) } }
                }
                for (station in guide.stations) {
                    Choosable(station.name, guide.station == station.serviceID) {
                        open = false
                        scope.launch { RecBridge.act { it.guide.chooseStation(station.serviceID) } }
                    }
                }
            }
        }
    }
}

/** A menu's item, ticked when it is the one chosen. */
@Composable
private fun Choosable(label: String, chosen: Boolean, choose: () -> Unit) {
    DropdownMenuItem(text = { Text(label) }, onClick = choose, leadingIcon = {
        if (chosen) Icon(Icons.Default.Check, contentDescription = null) else Spacer(Modifier.width(24.dp))
    })
}

/** The day, with a step either side; the day itself opens the days and 今, as the iOS guide's does. */
@Composable
private fun DayBar(guide: Guide) {
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center) {
        IconButton(onClick = { scope.launch { RecBridge.act { it.guide.chooseDay((guide.day - 1).toLong()) } } },
                   enabled = guide.day > 0) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = "前の日")
        }
        Box {
            TextButton(onClick = { open = true }) {
                Text(guide.days.getOrElse(guide.day) { "" }, style = MaterialTheme.typography.titleMedium)
                Icon(Icons.Default.ArrowDropDown, contentDescription = null)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                DropdownMenuItem(text = { Text("今") }, leadingIcon = { Icon(Icons.Outlined.Today, contentDescription = null) },
                                 onClick = {
                                     open = false
                                     scope.launch { RecBridge.act { it.guide.goToNow() } }
                                 })
                HorizontalDivider()
                guide.days.forEachIndexed { index, day ->
                    Choosable(day, index == guide.day) {
                        open = false
                        scope.launch { RecBridge.act { it.guide.chooseDay(index.toLong()) } }
                    }
                }
            }
        }
        IconButton(onClick = { scope.launch { RecBridge.act { it.guide.chooseDay((guide.day + 1).toLong()) } } },
                   enabled = guide.day < guide.days.size - 1) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = "次の日")
        }
    }
}

/**
 * The day's programmes. The list opens at what is on now, or on another day at its first, as the iOS list does, and
 * goes back there each time 今 is asked for.
 */
@Composable
private fun Programmes(guide: Guide, open: (Programme) -> Unit) {
    val now = minuteNow()
    val opening = guide.programmes.indexOfFirst { it.ends > now }.coerceAtLeast(0)
    // Made again for each list, so that a new one opens at its own place: by the programmes themselves, since the
    // day or the type changes first and the programmes read for it come after (on iOS, the guide's reads are waited
    // for, `guideReads`).
    val listed = with(guide.programmes) { "${size}-${firstOrNull()?.id}-${lastOrNull()?.id}" }
    val position = remember(listed) { LazyListState(firstVisibleItemIndex = opening) }
    var answered by remember { mutableLongStateOf(guide.nowRequests) }
    LaunchedEffect(guide.nowRequests) {
        if (guide.nowRequests != answered) {
            answered = guide.nowRequests
            position.scrollToItem(opening)
        }
    }
    // Each station's logo made once, not on each row it heads.
    val logos = remember(guide.stations) {
        guide.stations.filter { it.logo.isNotEmpty() }.associate { station ->
            station.serviceID to BitmapFactory.decodeByteArray(station.logo, 0, station.logo.size)?.asImageBitmap()
        }
    }
    LazyColumn(Modifier.fillMaxSize(), state = position) {
        items(guide.programmes, key = { it.id }) { programme ->
            ProgrammeRow(programme, logos[programme.serviceID], now) { open(programme) }
            HorizontalDivider()
        }
    }
}

/**
 * One programme, as the iOS row says it: the time and the length in a column of their own, then the title, the
 * station with its logo and the marks, and the summary. What is on air is marked; what is over is dimmed.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ProgrammeRow(item: Programme, logo: ImageBitmap?, now: Long, day: String = "",
                          found: AnnotatedString? = null, open: () -> Unit) {
    val onAir = item.starts <= now && now < item.ends
    val ended = item.ends <= now
    val colors = MaterialTheme.colorScheme
    val marks = LocalMarks.current
    Row(Modifier.fillMaxWidth().clickable(onClick = open).alpha(if (ended) 0.45f else 1f)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.width(if (day.isEmpty()) 48.dp else 64.dp), horizontalAlignment = Alignment.End) {
            if (day.isNotEmpty()) Text(day, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
            Text(item.time, style = MaterialTheme.typography.titleSmall)
            Text(item.length, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(item.title, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis,
                 fontWeight = if (onAir) FontWeight.SemiBold else FontWeight.Normal)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                val middle = Modifier.align(Alignment.CenterVertically)
                if (logo != null) Image(logo, contentDescription = null, middle.height(14.dp))
                Text(item.station, style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant, modifier = middle)
                if (onAir) Mark("放送中", colors.primaryContainer, colors.onPrimaryContainer, middle)
                if (item.mark.isNotEmpty()) {
                    if (item.markIsRed) Mark(item.mark, colors.errorContainer, colors.onErrorContainer, middle)
                    else Mark(item.mark, marks.reserved, marks.onReserved, middle)
                }
                if (item.genre.isNotEmpty()) {
                    Text(item.genre, style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant, modifier = middle)
                }
            }
            if (item.summary.isNotEmpty()) {
                Text(item.summary, style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis,
                     color = colors.onSurfaceVariant)
            }
            if (found != null) {
                Text(found, style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis,
                     color = colors.onSurfaceVariant)
            }
        }
    }
}
