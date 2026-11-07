package jp.hiroaki.bdbridge

import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

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

/** Where a recorder is chosen: its address, the search for both kinds, or the demo's invented recorder. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(state: AppState) {
    Scaffold(topBar = { TopAppBar(title = { Text("レコーダーにつなぐ") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                   verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                OutlinedTextField(
                    value = state.address, onValueChange = { state.address = it.trim() },
                    label = { Text("レコーダーのアドレス") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { state.connect(state.address) },
                           enabled = state.address.isNotEmpty() && !state.connecting) { Text("つなぐ") }
                    OutlinedButton(onClick = { state.search() }, enabled = !state.searching) {
                        Text("レコーダーとテレビを探す")
                    }
                }
            }
            if (state.connecting || state.searching) item { CircularProgressIndicator() }
            state.problem?.let { said ->
                item { Text(said, color = MaterialTheme.colorScheme.error) }
            }
            state.found?.let { found ->
                if (found.isEmpty()) {
                    item { Text("見つかりませんでした", style = MaterialTheme.typography.bodyMedium) }
                }
                items(found, key = { it.host + it.isRecorder }) { device ->
                    ListItem(
                        headlineContent = { Text(device.name) },
                        supportingContent = { Text("${if (device.isRecorder) "レコーダー" else "テレビ"} · ${device.host}") },
                        modifier = Modifier.clickable(enabled = device.isRecorder) { state.connect(device.host) },
                    )
                }
            }
            item {
                TextButton(onClick = { state.connectToTheDemo() }) { Text("レコーダーがない場合はデモで試す") }
            }
        }
    }
}

/** A recorder's reservations and recordings, read. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecorderScreen(state: AppState) {
    val recorder = state.recorder ?: return
    var tab by rememberSaveable { mutableIntStateOf(0) }
    Scaffold(topBar = {
        TopAppBar(
            title = {
                Column {
                    Text(recorder.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    // The demo is said apart, so that its invented rows are never taken for a real recorder's.
                    if (state.isDemo) Text("デモ", style = MaterialTheme.typography.labelMedium)
                }
            },
            actions = {
                IconButton(onClick = { state.readLists() }) {
                    Icon(Icons.Default.Refresh, contentDescription = "読み直す")
                }
                IconButton(onClick = { state.leave() }) {
                    Icon(Icons.AutoMirrored.Filled.ExitToApp, contentDescription = "レコーダーを切り替える")
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
                0 -> GuideView(state)
                1 -> LoadedList(state.reservations, empty = "予約はありません") { ReservationRowView(it) }
                else -> LoadedList(state.recordings, empty = "録画はありません") { RecordingRowView(it) }
            }
        }
    }
}

/** One station's programmes on one broadcast day, the station and the type chosen above them. */
@Composable
private fun GuideView(state: AppState) {
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for ((code, label) in listOf("td" to "地デジ", "bs" to "BS", "cs" to "CS")) {
                FilterChip(selected = state.broadcasting == code, onClick = { state.choose(code) }, label = { Text(label) })
            }
            Box(Modifier.weight(1f))
            TextButton(onClick = { state.refreshGuide() }, enabled = !state.refreshing) {
                Text(if (state.refreshing) "更新中" else "更新")
            }
        }
        state.guideSaid?.let { Text(it, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp)) }
        when (val stations = state.stations) {
            Loaded.Reading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            is Loaded.Failed -> Text(stations.said, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp))
            is Loaded.Read -> if (stations.items.isEmpty()) {
                Text("番組表がまだありません。「更新」でレコーダーから取ってきます", modifier = Modifier.padding(16.dp))
            } else {
                LazyRow(contentPadding = PaddingValues(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(stations.items, key = { it.serviceID }) { station ->
                        FilterChip(selected = state.station?.serviceID == station.serviceID,
                                   onClick = { state.choose(station) }, label = { Text(station.name, maxLines = 1) })
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 8.dp)) {
                    TextButton(onClick = { state.moveDay(-1) }, enabled = state.dayOffset > 0) { Text("前の日") }
                    Text(state.dayHeading, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                    TextButton(onClick = { state.moveDay(1) }, enabled = state.dayOffset < 7) { Text("次の日") }
                }
                LoadedList(state.programmes, empty = "この日の番組はありません") { ProgrammeRowView(it) }
            }
        }
    }
}

@Composable
private fun ProgrammeRowView(item: Programme) {
    ListItem(
        overlineContent = { Text(if (item.onAir) "${item.span} · 放送中" else item.span) },
        headlineContent = { Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(item.details) },
        modifier = Modifier.alpha(if (item.ended) 0.5f else 1f),
    )
}

@Composable
private fun <T> LoadedList(loaded: Loaded<T>, empty: String, row: @Composable (T) -> Unit) {
    when (loaded) {
        Loaded.Reading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        is Loaded.Failed -> Text(loaded.said, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp))
        is Loaded.Read -> if (loaded.items.isEmpty()) {
            Text(empty, modifier = Modifier.padding(16.dp))
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                items(loaded.items) { item ->
                    row(item)
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun ReservationRowView(item: ReservationItem) {
    ListItem(
        overlineContent = { Text("${item.date} · ${item.span}") },
        headlineContent = { Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            val marks = listOfNotNull(
                if (item.recording) "録画中" else null,
                if (item.conflict) "重複" else null,
            )
            Text((marks + item.details).joinToString(" · "))
        },
    )
}

@Composable
private fun RecordingRowView(item: RecordingItem) {
    ListItem(
        overlineContent = { Text(item.date) },
        headlineContent = { Text(item.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            val marks = listOfNotNull(
                if (item.recording) "録画中" else null,
                if (item.isNew) "未視聴" else null,
                if (item.protected) "保護" else null,
            )
            Text((marks + item.details).joinToString(" · "))
        },
    )
}
