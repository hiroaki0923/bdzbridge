package jp.hiroaki.bdbridge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.VideoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

// What the recordings' screen has beyond its list, as the iOS app has it: the bulk job's bar, a programme's page with
// the selection that bulk work needs, and the recordings that look like copies of one broadcast. What each offers,
// holds back and says is the model's (core/.../Recordings.swift).

/**
 * The bulk job, wherever the reader happens to be looking: on the recordings' screen and on a programme's page, so
 * that leaving the page never takes away the way to stop what it started. Nothing while there is no job.
 */
@Composable
fun JobBarView() {
    val job = RecBridge.job.collectAsState().value ?: return
    if (!job.hasJob) return
    val scope = rememberCoroutineScope()
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 8.dp),
               verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!job.finished) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Text(job.line, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                if (job.finished) {
                    IconButton(onClick = { scope.launch { RecBridge.act { it.job.clear() } } }) {
                        Icon(Icons.Default.Close, contentDescription = "閉じる", Modifier.size(18.dp))
                    }
                } else {
                    if (job.stopping.isNotEmpty()) Footnote(job.stopping)
                    TextButton(onClick = { scope.launch { RecBridge.act { it.job.cancel() } } },
                               enabled = job.stopping.isEmpty()) { Text("中止") }
                }
            }
            if (!job.finished) {
                LinearProgressIndicator(progress = { job.progress / 100f }, modifier = Modifier.fillMaxWidth().padding(end = 12.dp))
                Footnote(job.note)
            }
            if (job.why.isNotEmpty()) Footnote(job.why)
            for (line in job.passedOver) Footnote(line)
        }
    }
    HorizontalDivider()
}

/** A programme's row in まとめ: its name, how many and how big with what is new or protected, and from when to when. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun GroupRowView(group: GroupItem, open: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    ListItem(
        headlineContent = { Text(group.name, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(group.count)
                    Text(group.size)
                    if (group.unwatched.isNotEmpty()) Text(group.unwatched, color = colors.primary)
                    if (group.locked.isNotEmpty()) Text(group.locked)
                }
                Text(group.span)
            }
        },
        modifier = Modifier.clickable(onClick = open),
    )
    HorizontalDivider()
}

/**
 * One programme's recordings, over the recordings' screen with the way back: the selection that bulk work needs, the
 * runs it starts, and each row's own sheet, delete and 保護解除. It is not left while a request of its own is out, so
 * that what it came to is said here.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun GroupPage(group: GroupItem, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val colors = MaterialTheme.colorScheme
    val handle = rememberOpened(group.id) { RecBridge.openGroup(group.id) }
    val shown = handle?.let { it.shown.collectAsState().value }
    val act = { work: suspend RecBridge.GroupHandle.() -> Unit -> handle?.let { scope.launch { it.work() } }; Unit }
    val held = shown?.asking ?: false
    BackHandler(enabled = true) { if (!held) close() }
    LaunchedEffect(shown?.done) { if (shown?.done == true) close() }
    var opened by remember { mutableStateOf<RecordingItem?>(null) }
    opened?.let { row -> TitleSheetView(row, open = { handle?.open(row.id) }) { opened = null } }
    shown?.asked?.let { asked ->
        AskDialog(asked, act = { act { act(asked.key) } }, closeAsked = { act { closeAsked(asked.key) } },
                  actionEnabled = !shown.actionHeld)
    }
    Scaffold(topBar = {
        Column {
            TopAppBar(
                title = { Text(shown?.name ?: group.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    IconButton(onClick = close, enabled = !held) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る")
                    }
                },
                actions = {
                    TextButton(onClick = { act { toggleSelecting() } }, enabled = shown != null && !shown.selectHeld) {
                        Text(shown?.selectLabel ?: "選択")
                    }
                    ProtectAll(enabled = shown != null && !shown.protectAllHeld) { on -> act { protectAll(on) } }
                },
            )
            JobBarView()
            if (shown?.selecting == true) {
                Surface(color = colors.surfaceContainer) {
                    // Wrapped where the three do not fit side by side, as on a narrow phone.
                    FlowRow(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalArrangement = Arrangement.Center) {
                        TextButton(onClick = { act { selectWhatCanBeDeleted() } }) { Text("削除できるものをすべて選択") }
                        TextButton(onClick = { act { selectNothing() } }) { Text("選択解除") }
                        Text(shown.count, style = MaterialTheme.typography.labelLarge, color = colors.onSurfaceVariant,
                             maxLines = 1, softWrap = false,
                             modifier = Modifier.align(Alignment.CenterVertically).padding(horizontal = 12.dp))
                    }
                }
            }
        }
    }, bottomBar = {
        if (shown?.offersActions == true) {
            Surface(color = colors.surfaceContainer) {
                Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { act { deleteChosen() } }, enabled = !shown.actionsHeld,
                           colors = ButtonDefaults.buttonColors(containerColor = colors.error, contentColor = colors.onError),
                           modifier = Modifier.fillMaxWidth()) { Text(shown.deleteLabel) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { act { protect(true) } }, enabled = !shown.actionsHeld) { Text("保護する") }
                        OutlinedButton(onClick = { act { protect(false) } }, enabled = !shown.actionsHeld) { Text("保護を解除") }
                    }
                }
            }
        }
    }) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            if (shown == null) return@Box CircularProgressIndicator(Modifier.align(Alignment.Center))
            LazyColumn(Modifier.fillMaxSize()) {
                items(shown.rows, key = { it.row.id }) { member ->
                    val row = member.row
                    if (shown.selecting) {
                        // The tick, said to a screen reader as the row being selected; grey where a bulk delete would
                        // pass the recording over.
                        Row(Modifier.semantics { selected = member.selected }, verticalAlignment = Alignment.CenterVertically) {
                            Icon(if (member.selected) Icons.Default.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                                 contentDescription = null, Modifier.padding(start = 16.dp),
                                 tint = if (member.wouldBeDeleted) colors.primary else colors.onSurfaceVariant)
                            Column(Modifier.weight(1f)) { RecordingRow(row) { act { toggle(row.id) } } }
                        }
                    } else {
                        RecordingSwipes(row, delete = { act { delete(row.id) } }, unprotect = { act { unprotect(row.id) } }) {
                            RecordingRow(row) { opened = row }
                        }
                    }
                }
            }
        }
    }
}

/** The menu that protects every recording of the programme, or takes the protection off them all. */
@Composable
private fun ProtectAll(enabled: Boolean, protect: (Boolean) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }, enabled = enabled) {
            Icon(Icons.Default.MoreVert, contentDescription = "保護をまとめて変更")
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text("この番組をすべて保護") }, onClick = {
                open = false
                protect(true)
            })
            DropdownMenuItem(text = { Text("この番組の保護をすべて解除") }, onClick = {
                open = false
                protect(false)
            })
        }
    }
}

/**
 * A recording's row with what a swipe to the left asks for, by what the model offers for it: 削除, asked first, or
 * 保護解除 on a protected one, which has to happen before it can be deleted; nothing where it offers nothing.
 */
@Composable
fun RecordingSwipes(row: RecordingItem, delete: () -> Unit, unprotect: () -> Unit, content: @Composable () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val marks = LocalMarks.current
    val action = when (row.swipe) {
        "delete" -> SwipeAction("削除", colors.errorContainer, colors.onErrorContainer, !row.held, delete)
        "unprotect" -> SwipeAction("保護解除", marks.reserved, marks.onReserved, !row.held, unprotect)
        else -> null
    }
    SwipeActions(toTheRight = null, toTheLeft = action, content = content)
}

/**
 * The recordings that look like copies of one broadcast. A tick deletes, and whatever is left unticked is marked as
 * kept. With no sets yet, what is said in their place and the scan it offers.
 */
@Composable
fun DuplicatesView(open: (RecordingItem) -> Unit) {
    val shown = RecBridge.duplicates.collectAsState().value ?: return
    val scope = rememberCoroutineScope()
    val colors = MaterialTheme.colorScheme
    val scan = { scope.launch { RecBridge.act { it.duplicates.scan() } }; Unit }
    shown.asked?.let { asked ->
        AskDialog(asked, act = { scope.launch { RecBridge.act { it.duplicates.act(asked.key) } } },
                  closeAsked = { scope.launch { RecBridge.act { it.duplicates.closeAsked(asked.key) } } },
                  actionEnabled = !shown.actionHeld)
    }
    if (!shown.hasSets) {
        return Unavailable(Icons.Outlined.ContentCopy, shown.promptTitle, shown.promptDetail) {
            Button(onClick = scan, enabled = !shown.scanHeld) { Text(shown.scanLabel) }
        }
    }
    Column(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.weight(1f)) {
            item(key = "explanation") { Footnote(shown.explanation, Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) }
            if (shown.unread.isNotEmpty()) {
                item(key = "unread") {
                    Column(Modifier.padding(horizontal = 16.dp)) {
                        Footnote(shown.unread)
                        TextButton(onClick = scan, enabled = !shown.scanAgainHeld) { Text("もう一度調べる") }
                    }
                }
            }
            for (set in shown.sets) {
                item(key = "set-" + set.id) {
                    Surface(color = colors.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                            Text(set.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Footnote(set.details)
                        }
                    }
                }
                items(set.copies, key = { set.id + "-" + it.id }) { copy -> CopyRow(copy, set.title, open) }
            }
        }
        if (shown.deleteLabel.isNotEmpty()) {
            Surface(color = colors.surfaceContainer) {
                Button(onClick = { scope.launch { RecBridge.act { it.duplicates.delete() } } }, enabled = !shown.deleteHeld,
                       colors = ButtonDefaults.buttonColors(containerColor = colors.error, contentColor = colors.onError),
                       modifier = Modifier.fillMaxWidth().padding(12.dp)) { Text(shown.deleteLabel) }
            }
        }
    }
}

/**
 * One copy: its tick, read out as what it does; 残す or 削除 with why, and the lock on a protected one; then when it
 * was recorded and what it is. The row opens the recording's sheet.
 */
@Composable
private fun CopyRow(copy: Copy, title: String, open: (RecordingItem) -> Unit) {
    val scope = rememberCoroutineScope()
    val colors = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().clickable { open(RecordingItem(copy.id, title)) }.padding(end = 16.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked = !copy.keeping, enabled = !copy.tickHeld,
                 onCheckedChange = { scope.launch { RecBridge.act { it.duplicates.toggle(copy.id) } } },
                 modifier = Modifier.semantics { contentDescription = copy.tickLabel })
        Column(Modifier.weight(1f).padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                if (copy.keeping) Mark(copy.mark, colors.primaryContainer, colors.onPrimaryContainer)
                else Mark(copy.mark, colors.errorContainer, colors.onErrorContainer)
                Footnote(copy.reason)
                if (copy.protected) Icon(Icons.Default.Lock, contentDescription = "保護", Modifier.size(12.dp), tint = colors.onSurfaceVariant)
            }
            Text(copy.recorded, style = MaterialTheme.typography.bodyMedium)
            Footnote(copy.details)
        }
    }
    HorizontalDivider()
}
