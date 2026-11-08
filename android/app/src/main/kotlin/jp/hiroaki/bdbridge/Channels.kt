package jp.hiroaki.bdbridge

import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.outlined.SatelliteAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import kotlinx.coroutines.launch

/**
 * Which stations the guide shows, and in what order, one broadcasting type at a time (core/.../Channels.swift): a
 * switch on each to show it, and the handle at its end to drag it to another place. Over the screens, with the way
 * back; opened from the settings, from the guide's menu, and from a guide with every station hidden.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChannelsPage(close: () -> Unit) {
    BackHandler(onBack = close)
    val scope = rememberCoroutineScope()
    val handle = rememberOpened(Unit) { RecBridge.openChannels() }
    val shown = handle?.shown?.collectAsState()?.value
    var resetting by remember { mutableStateOf(false) }
    Scaffold(topBar = {
        TopAppBar(title = { Text("チャンネルの表示と並び順", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                  navigationIcon = { IconButton(onClick = close) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            if (handle == null || shown == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                return@Column
            }
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                shown.types.forEachIndexed { index, type ->
                    SegmentedButton(selected = type.code == shown.broadcasting,
                                    onClick = { scope.launch { handle.choose(type.code) } },
                                    shape = SegmentedButtonDefaults.itemShape(index, shown.types.size)) { Text(type.label) }
                }
            }
            // The list is made once it has been read: made empty, it would keep its place at the foot it had then, and
            // open scrolled past the first station.
            when {
                !shown.loaded -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                shown.stations.isEmpty() -> Unavailable(Icons.Outlined.SatelliteAlt, shown.emptyTitle, shown.emptyDetail)
                else -> Stations(shown, handle) { resetting = true }
            }
        }
    }
    if (resetting && shown != null && handle != null) {
        AlertDialog(onDismissRequest = { resetting = false },
                    text = { Text(shown.resetQuestion) },
                    confirmButton = {
                        TextButton(onClick = {
                            resetting = false
                            scope.launch { handle.reset() }
                        }) { Text("レコーダーの順に戻す") }
                    },
                    dismissButton = { TextButton(onClick = { resetting = false }) { Text("キャンセル") } })
    }
    if (shown != null && handle != null && shown.failure.isNotEmpty()) {
        AlertDialog(onDismissRequest = { scope.launch { handle.failureClosed() } },
                    confirmButton = { TextButton(onClick = { scope.launch { handle.failureClosed() } }) { Text("OK") } },
                    title = { Text("保存できませんでした") }, text = { Text(shown.failure) })
    }
}

/** The stations, each with its switch and its handle, then what the screen says and the reset. */
@Composable
private fun Stations(shown: Channels, handle: RecBridge.ChannelsHandle, reset: () -> Unit) {
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    val edge = with(LocalDensity.current) { 56.dp.toPx() }
    val dragging = remember(list) { Dragging(list) }
    // The list as the model has it, once it has caught up with the station dropped: by the stations' order, since a
    // station's logo makes it unequal to the same station read again.
    LaunchedEffect(shown.stations.map { it.id }) { dragging.caughtUp() }
    // Held near the top or the foot of the list, the list scrolls on by itself, a frame at a time, until let go.
    LaunchedEffect(dragging.id) {
        if (dragging.id == null) return@LaunchedEffect
        while (true) {
            val step = dragging.stepAtTheEdge(edge)
            if (step != 0f) dragging.scrolled(list.scrollBy(step))
            withFrameNanos {}
        }
    }
    // Each station's logo made once, not at each turn of the list.
    val logos = remember(shown.stations.map { it.id }) {
        shown.stations.filter { it.logo.isNotEmpty() }.associate { station ->
            station.id to BitmapFactory.decodeByteArray(station.logo, 0, station.logo.size)?.asImageBitmap()
        }
    }
    val rows = dragging.rows ?: shown.stations
    LazyColumn(state = list, modifier = Modifier.fillMaxSize()) {
        itemsIndexed(rows, key = { _, station -> station.id }) { _, station ->
            val held = station.id == dragging.id
            ListItem(
                leadingContent = {
                    // The space is held where a station has no logo, so that the names line up.
                    Box(Modifier.size(width = 36.dp, height = 18.dp)) {
                        logos[station.id]?.let { Image(it, contentDescription = null, Modifier.fillMaxSize()) }
                    }
                },
                headlineContent = {
                    Text(station.name, maxLines = 1,
                         color = if (station.shown) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
                },
                trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Switch(checked = station.shown, onCheckedChange = { on -> scope.launch { handle.show(station.id, on) } })
                        Icon(Icons.Default.DragHandle, contentDescription = "並べ替え",
                             modifier = Modifier.padding(start = 8.dp).size(40.dp).padding(8.dp).pointerInput(station.id) {
                                 detectDragGestures(
                                     onDragStart = { dragging.start(station.id, shown.stations) },
                                     onDrag = { change, amount ->
                                         change.consume()
                                         dragging.drag(amount.y)
                                     },
                                     onDragEnd = { dragging.drop()?.let { move -> scope.launch { dragging.moved(handle.move(move.id, move.from, move.to)) } } },
                                     onDragCancel = { dragging.drop()?.let { move -> scope.launch { dragging.moved(handle.move(move.id, move.from, move.to)) } } },
                                 )
                             })
                    }
                },
                colors = if (held) ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh)
                         else ListItemDefaults.colors(),
                tonalElevation = if (held) 3.dp else 0.dp,
                modifier = if (held) Modifier.zIndex(1f).graphicsLayer { translationY = dragging.offset }
                           else Modifier.animateItem(),
            )
        }
        item(key = "foot") {
            Column(Modifier.padding(16.dp)) {
                Footnote(shown.footer)
                OutlinedButton(onClick = reset, enabled = shown.customised, modifier = Modifier.padding(top = 16.dp)) {
                    Text("レコーダーの順に戻して、すべて表示")
                }
            }
        }
    }
}

/**
 * A station held by its handle: the rows in the order the drag has made, the held one drawn where the finger is, and
 * the place it was picked up from. The order is the screen's until the station is dropped, and the model's once it
 * has caught up; the model is told of the move once, as it is dropped.
 */
private class Dragging(private val list: LazyListState) {
    var id by mutableStateOf<String?>(null)
        private set
    var rows by mutableStateOf<List<ArrangedStation>?>(null)
        private set
    var offset by mutableFloatStateOf(0f)
        private set
    private var from = -1

    fun start(id: String, stations: List<ArrangedStation>) {
        this.id = id
        rows = stations
        from = stations.indexOfFirst { it.id == id }
        offset = 0f
    }

    /** The finger has moved by `by`: the held row goes past a neighbour its middle has crossed. */
    fun drag(by: Float) {
        offset += by
        val rows = rows ?: return
        val visible = list.layoutInfo.visibleItemsInfo
        val held = visible.firstOrNull { it.key == id } ?: return
        val middle = held.offset + offset + held.size / 2f
        val over = visible.firstOrNull { item ->
            item.key != id && rows.any { it.id == item.key } && middle > item.offset && middle < item.offset + item.size
        } ?: return
        val at = rows.indexOfFirst { it.id == id }
        val to = rows.indexOfFirst { it.id == over.key }
        // The list keeps its place by its first row's key: that row moved, the list would scroll with it, so the place
        // is asked for again at the next measure, as Compose has a moved first row kept.
        val first = list.firstVisibleItemIndex
        val firstOffset = list.firstVisibleItemScrollOffset
        this.rows = rows.toMutableList().apply { add(to, removeAt(at)) }
        if (held.index == first || over.index == first) list.requestScrollToItem(first, firstOffset)
        // The row now has the neighbour's place, and is drawn from there where the finger still is.
        offset += held.offset - over.offset
    }

    /** How far to scroll the list on at this frame: towards the edge the held row is near, nothing elsewhere. */
    fun stepAtTheEdge(edge: Float): Float {
        val info = list.layoutInfo
        val held = info.visibleItemsInfo.firstOrNull { it.key == id } ?: return 0f
        val top = held.offset + offset
        val bottom = top + held.size
        return when {
            top < info.viewportStartOffset + edge && list.canScrollBackward -> -12f
            bottom > info.viewportEndOffset - edge && list.canScrollForward -> 12f
            else -> 0f
        }
    }

    /** The list scrolled under the held row by `by`, which stays under the finger. */
    fun scrolled(by: Float) {
        if (by == 0f) return
        offset += by
        drag(0f)
    }

    /** A station moved by the drag, from where it was picked up to where it was let go. */
    class Move(val id: String, val from: Int, val to: Int)

    /** Let go of: the move, or nothing where it is back where it was. */
    fun drop(): Move? {
        val held = id
        val to = rows?.indexOfFirst { it.id == held } ?: -1
        val move = if (held != null && from >= 0 && to >= 0 && to != from) Move(held, from, to) else null
        id = null
        offset = 0f
        if (move == null) rows = null
        return move
    }

    /** What the model made of the move: refused, the list goes back to the model's at once. */
    fun moved(taken: Boolean) {
        if (!taken && id == null) rows = null
    }

    /** The model's list has come in: the order the drag made is the model's now. */
    fun caughtUp() {
        if (id == null) rows = null
    }
}
