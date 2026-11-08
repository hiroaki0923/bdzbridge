package jp.hiroaki.bdbridge

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SheetValue
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Switch
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch

// The programme's sheet and the reservation's, as the iOS sheets lay them out: what each holds, offers, holds back
// and says, and what each press does, are the model's, through the sheets' windows (core/.../Sheets.swift). A sheet
// opens at once with what the row it was opened from already says, and the rest comes in as its window is read.

/**
 * A sheet's window, opened as the sheet comes up and closed as it goes. The opening runs where the sheet going does
 * not cancel it, and a window that comes back for a sheet already gone is closed at once: left open, it would go on
 * following the model, and asking the recorder, for nobody.
 */
@Composable
fun <H : RecBridge.Sheet<*>> rememberOpened(key: Any, open: suspend () -> H?): H? {
    var handle by remember(key) { mutableStateOf<H?>(null) }
    DisposableEffect(key) {
        var gone = false
        RecBridge.launch {
            val opened = open()
            if (gone) opened?.close() else handle = opened
        }
        onDispose {
            gone = true
            handle?.close()
        }
    }
    return handle
}

/**
 * A bottom sheet that cannot be put away while a request of its own is out: what the request came to is said on it,
 * and a sheet that had gone would say it nowhere. It opens at its full height, as an iOS sheet does: half open, its
 * buttons -- 録画予約する, 予約を削除 -- were below the edge, with nothing to say that the sheet went further up.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HeldSheet(held: Boolean, done: Boolean, close: () -> Unit, content: @Composable () -> Unit) {
    val holding by rememberUpdatedState(held)
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true,
                                              confirmValueChange = { it != SheetValue.Hidden || !holding })
    // Closed by the sheet itself -- its reservation made, its delete gone through -- the sheet slides away first and
    // is taken off only then, as Material has a sheet closed from code: taken off at once, its window was still
    // there for a moment, and a tap on the screen beneath went to it.
    LaunchedEffect(done) {
        if (done) {
            try {
                state.hide()
            } finally {
                close()
            }
        }
    }
    ModalBottomSheet(onDismissRequest = { if (!holding) close() }, sheetState = state) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp).navigationBarsPadding()) {
            content()
        }
    }
}

/**
 * The one question or answer up at a time: the button that does something, if any, and the one that closes. A
 * question is answered by its buttons, as an iOS alert is, and not put away by a touch beside it; the back key is
 * its closing button. An answer with OK alone goes either way.
 */
@Composable
private fun AskDialog(asked: Asked, act: () -> Unit, closeAsked: () -> Unit, actionEnabled: Boolean = true) {
    val closing = @Composable { TextButton(onClick = closeAsked) { Text(asked.closing) } }
    AlertDialog(
        onDismissRequest = closeAsked,
        properties = DialogProperties(dismissOnClickOutside = asked.action.isEmpty()),
        title = { Text(asked.title) },
        text = { Text(asked.message) },
        confirmButton = {
            if (asked.action.isEmpty()) closing()
            else TextButton(onClick = act, enabled = actionEnabled) {
                Text(asked.action, color = when {
                    !actionEnabled -> Color.Unspecified
                    asked.destructive -> MaterialTheme.colorScheme.error
                    else -> Color.Unspecified
                })
            }
        },
        dismissButton = if (asked.action.isEmpty()) null else closing,
    )
}

/** The programme's sheet: what it is, the reservations of it, and 録画予約 where it is offered. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProgrammeSheetView(row: Programme, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val handle = rememberOpened(row.id) { RecBridge.openProgramme(row.id) }
    val sheet = handle?.let { it.shown.collectAsState().value }
    var editing by remember { mutableStateOf<String?>(null) }
    val act = { work: suspend RecBridge.ProgrammeSheetHandle.() -> Unit -> handle?.let { scope.launch { it.work() } }; Unit }
    val free = sheet != null && sheet.asking.isEmpty()

    HeldSheet(held = sheet?.held ?: false, done = sheet?.done ?: false, close = close) {
        Title(sheet?.title ?: row.title)
        sheet?.waking?.takeIf { it.isNotEmpty() }?.let { Working(it) }
        Value("放送", sheet?.station ?: row.station)
        Value("開始", sheet?.starts ?: row.time)
        Value("長さ", sheet?.length ?: row.length)
        (sheet?.genre ?: row.genre).takeIf { it.isNotEmpty() }?.let { Value("ジャンル", it) }
        if (sheet == null) {
            Working("")
        } else {
            sheet.recorders?.let { held ->
                HeldSection(held, enabled = free, change = { editing = "recorder" }, delete = { act { delete("recorder") } })
            }
            sheet.televisions?.let { held ->
                HeldSection(held, enabled = free, change = { editing = "tv" }, delete = { act { delete("tv") } })
            }
            sheet.waitingForTheRecorder?.let { waiting ->
                WaitingSection(waiting, free, sendAgain = { act { sendAgain("recorder") } }, delete = { act { deleteWaiting("recorder") } })
            }
            sheet.waitingForTheTelevision?.let { waiting ->
                WaitingSection(waiting, free, sendAgain = { act { sendAgain("tv") } }, delete = { act { deleteWaiting("tv") } })
            }
            if (sheet.asking.isNotEmpty()) Working(sheet.asking)
            if (sheet.offer.isNotEmpty()) Offer(sheet, free, act)
        }
        (sheet?.summary ?: row.summary).takeIf { it.isNotEmpty() }?.let { Part("番組内容", it) }
        sheet?.extended?.takeIf { it.isNotEmpty() }?.let { Part("詳細", it) }
        sheet?.problem?.takeIf { it.isNotEmpty() }?.let { Problem(it) }
    }
    sheet?.asked?.let { asked -> AskDialog(asked, act = { act { act(asked.key) } }, closeAsked = { act { closeAsked(asked.key) } }) }
    editing?.let { device ->
        val opened = handle ?: return@let
        ReservationSheetView(row.title, open = { opened.change(device) }, close = {
            editing = null
            scope.launch { opened.changeClosed() }
        })
    }
}

/** 録画予約: where it goes, the recorder's disk, the mode, the repeat, what it would clash with, and the button. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Offer(sheet: ProgrammeSheetScreen, free: Boolean,
                  act: (suspend RecBridge.ProgrammeSheetHandle.() -> Unit) -> Unit) {
    SectionHeading("録画予約")
    if (sheet.destinations.isNotEmpty()) {
        ListItem(headlineContent = { Text("予約先") }, colors = clear(), trailingContent = {
            SingleChoiceSegmentedButtonRow {
                sheet.destinations.forEachIndexed { index, choice ->
                    SegmentedButton(selected = sheet.device == choice.code, enabled = free,
                                    onClick = { act { chooseDevice(choice.code) } },
                                    shape = SegmentedButtonDefaults.itemShape(index, sheet.destinations.size)) { Text(choice.label) }
                }
            }
        })
    } else if (sheet.destinationAlone.isNotEmpty()) {
        Value("予約先", sheet.destinationAlone)
    }
    if (sheet.disks.isNotEmpty()) Pick("録画先", sheet.disks, sheet.disk, free) { act { chooseDisk(it) } }
    else if (sheet.diskAlone.isNotEmpty()) Value("録画先", sheet.diskAlone)
    if (sheet.qualities.isNotEmpty()) Pick("録画モード", sheet.qualities, sheet.quality, free) { act { chooseQuality(it) } }
    else Value("録画モード", sheet.qualityAlone)
    Pick("毎回録画", sheet.repeats, sheet.repeating, free) { act { chooseRepeat(it) } }
    if (sheet.offer == "recorder") Clashes(sheet)
    Button(onClick = { act { reserve() } }, enabled = free && !sheet.reserveHeld,
           modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp)) { Text("録画予約する") }
}

/** What the recorder answers when asked what the reservation would clash with. */
@Composable
private fun Clashes(sheet: ProgrammeSheetScreen) {
    val marks = LocalMarks.current
    when {
        sheet.checking -> Working(sheet.checkingLine)
        sheet.conflictsLine.isNotEmpty() -> Column(Modifier.padding(horizontal = 24.dp, vertical = 4.dp),
                                                   verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(if (sheet.clashes) Icons.Outlined.WarningAmber else Icons.Outlined.CheckCircle, contentDescription = null,
                     Modifier.size(18.dp), tint = if (sheet.clashes) marks.onReserved else MaterialTheme.colorScheme.onSurfaceVariant)
                Text(sheet.conflictsLine, style = MaterialTheme.typography.bodyMedium,
                     color = if (sheet.clashes) marks.onReserved else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            for (conflict in sheet.conflicts) Footnote(conflict)
        }
    }
}

/** A device's reservation of the programme, with the way to change it and to delete it. */
@Composable
private fun HeldSection(held: HeldReservation, enabled: Boolean, change: () -> Unit, delete: () -> Unit) {
    SectionHeading(held.heading)
    if (held.quality.isNotEmpty()) Value("録画モード", held.quality)
    Value("毎回録画", held.repeating)
    if (held.disk.isNotEmpty()) Value("録画先", held.disk)
    if (held.recording) Problem("録画中です")
    Row(Modifier.padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (held.offersChanging) OutlinedButton(onClick = change, enabled = enabled && !held.changeHeld) { Text("予約を変更する") }
        Destructive("予約を削除", enabled && !held.deleteHeld, delete)
    }
    if (held.problem.isNotEmpty()) Problem(held.problem)
}

/** A reservation waiting on this device: what was asked for, and what the device said if it refused it. */
@Composable
private fun WaitingSection(waiting: WaitingReservation, enabled: Boolean, sendAgain: () -> Unit, delete: () -> Unit) {
    SectionHeading(waiting.heading)
    Value("録画モード", waiting.quality)
    Value("毎回録画", waiting.repeating)
    if (waiting.disk.isNotEmpty()) Value("録画先", waiting.disk)
    if (waiting.problem.isNotEmpty()) Problem(waiting.problem) else Footnote(waiting.notYet, Modifier.padding(horizontal = 24.dp))
    Row(Modifier.padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (waiting.problem.isNotEmpty()) {
            OutlinedButton(onClick = sendAgain, enabled = enabled && !waiting.sendAgainHeld) { Text("もう一度送る") }
        }
        Destructive("送信待ちの予約を削除", enabled && !waiting.deleteHeld, delete)
    }
}

/**
 * The reservation's sheet: the reservation as the device that holds it has it, what can still be changed of it and
 * the change to send, and its delete. Opened from the reservations' list, or from a programme's sheet over it.
 */
@Composable
fun ReservationSheetView(title: String, open: suspend () -> RecBridge.ReservationSheetHandle?, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val handle = rememberOpened(Unit, open)
    val sheet = handle?.let { it.shown.collectAsState().value }
    val act = { work: suspend RecBridge.ReservationSheetHandle.() -> Unit -> handle?.let { scope.launch { it.work() } }; Unit }
    val free = sheet != null && sheet.asking.isEmpty()

    HeldSheet(held = sheet?.asking?.isNotEmpty() ?: false, done = sheet?.done ?: false, close = close) {
        Title(sheet?.title ?: title)
        if (sheet == null) return@HeldSheet Working("")
        if (sheet.waking.isNotEmpty()) Working(sheet.waking)
        Value("放送", sheet.station)
        Value("開始", sheet.starts)
        Value("長さ", sheet.length)
        if (sheet.settled) {
            if (sheet.qualityValue.isNotEmpty()) Value("録画モード", sheet.qualityValue)
            Value("毎回録画", sheet.repeatValue)
        } else {
            if (sheet.qualities.isNotEmpty()) Pick("録画モード", sheet.qualities, sheet.quality, free) { act { chooseQuality(it) } }
            else if (sheet.qualityValue.isNotEmpty()) Value("録画モード", sheet.qualityValue)
            Pick("毎回録画", sheet.repeats, sheet.repeating, free) { act { chooseRepeat(it) } }
        }
        if (sheet.disks.isNotEmpty()) Pick("録画先", sheet.disks, sheet.disk, free) { act { chooseDisk(it) } }
        else if (sheet.diskAlone.isNotEmpty()) Value("録画先", sheet.diskAlone)
        if (sheet.follows.isNotEmpty()) Value("番組追従", sheet.follows)
        if (sheet.madeBy.isNotEmpty()) Value("登録元", sheet.madeBy)
        if (sheet.size.isNotEmpty()) Value("録画サイズ", sheet.size)
        if (sheet.recording) Problem("録画中です")
        if (sheet.conflict) {
            Column(Modifier.padding(horizontal = 24.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(sheet.clashLine, color = LocalMarks.current.onReserved, style = MaterialTheme.typography.bodyMedium)
                if (sheet.overlapping.isEmpty()) Footnote(sheet.noneOverlapping)
                else {
                    Text(sheet.overlappingHeading, style = MaterialTheme.typography.labelMedium)
                    for (other in sheet.overlapping) Footnote(other)
                }
            }
        }
        if (sheet.madeByItself.isNotEmpty()) Footnote(sheet.madeByItself, Modifier.padding(horizontal = 24.dp, vertical = 4.dp))
        if (sheet.summary.isNotEmpty()) Part("番組内容", sheet.summary)
        if (sheet.extended.isNotEmpty()) Part("詳細", sheet.extended)
        if (sheet.asking.isNotEmpty()) Working(sheet.asking)
        if (sheet.changed) {
            Button(onClick = { act { sendTheChange() } }, enabled = free && !sheet.buttonsHeld,
                   modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 4.dp)) { Text(sheet.changeLabel) }
            Footnote(sheet.changeFooter, Modifier.padding(horizontal = 24.dp))
        }
        Box(Modifier.padding(horizontal = 24.dp)) { Destructive("予約を削除", free && !sheet.buttonsHeld) { act { delete() } } }
        if (sheet.problem.isNotEmpty()) Problem(sheet.problem)
    }
    sheet?.asked?.let { asked ->
        AskDialog(asked, act = { act { confirmDelete(asked.key) } }, closeAsked = { act { closeAsked(asked.key) } })
    }
}

/**
 * The recording's sheet: what it is, playing it on the television, protecting it, and deleting it, as the iOS sheet
 * lays them out. It opens at once with what the row says.
 */
@Composable
fun TitleSheetView(row: RecordingItem, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val handle = rememberOpened(row.id) { RecBridge.openRecording(row.id) }
    val sheet = handle?.let { it.shown.collectAsState().value }
    val act = { work: suspend RecBridge.TitleSheetHandle.() -> Unit -> handle?.let { scope.launch { it.work() } }; Unit }

    HeldSheet(held = sheet?.asking ?: false, done = sheet?.done ?: false, close = close) {
        Title(sheet?.title ?: row.title)
        if (sheet == null) {
            Footnote(row.details, Modifier.padding(horizontal = 24.dp))
            return@HeldSheet Working("")
        }
        if (sheet.line.isNotEmpty()) Working(sheet.line)
        Value("放送", sheet.station)
        Value("録画", sheet.recorded)
        if (sheet.length.isNotEmpty()) Value("長さ", sheet.length)
        if (sheet.size.isNotEmpty()) Value("サイズ", sheet.size)
        if (sheet.quality.isNotEmpty()) Value("録画モード", sheet.quality)
        if (sheet.disk.isNotEmpty()) Value("録画先", sheet.disk)
        Value("視聴状態", sheet.viewing)
        if (sheet.genre.isNotEmpty()) Value("ジャンル", sheet.genre)
        if (sheet.offersPlayback) {
            SectionHeading("テレビで再生")
            FlowRowOfButtons {
                OutlinedButton(onClick = { act { play("play") } }, enabled = !sheet.playHeld) {
                    Icon(Icons.Default.PlayArrow, contentDescription = null, Modifier.size(18.dp))
                    Text(" " + sheet.playLabel)
                }
                OutlinedButton(onClick = { act { play("pause") } }, enabled = !sheet.playbackHeld) {
                    Icon(Icons.Default.Pause, contentDescription = null, Modifier.size(18.dp))
                    Text(" 一時停止 / 再開")
                }
                OutlinedButton(onClick = { act { play("stop") } }, enabled = !sheet.playbackHeld) {
                    Icon(Icons.Default.Stop, contentDescription = null, Modifier.size(18.dp))
                    Text(" 停止")
                }
                if (sheet.offersPower) {
                    OutlinedButton(onClick = { act { powerOn() } }, enabled = !sheet.playbackHeld) {
                        Icon(Icons.Default.PowerSettingsNew, contentDescription = null, Modifier.size(18.dp),
                             tint = LocalMarks.current.onReserved)
                        Text(" レコーダーの電源を入れる", color = LocalMarks.current.onReserved)
                    }
                }
            }
            Footnote(sheet.playbackNote, Modifier.padding(horizontal = 24.dp, vertical = 4.dp))
        }
        HorizontalDivider(Modifier.padding(top = 8.dp))
        ListItem(headlineContent = { Text(sheet.protectLabel) }, colors = clear(), modifier = Modifier.padding(horizontal = 8.dp),
                 trailingContent = {
                     Switch(checked = sheet.protected, enabled = !sheet.protectHeld,
                            onCheckedChange = { on -> act { setProtected(on) } })
                 })
        Box(Modifier.padding(horizontal = 24.dp)) { Destructive("この録画を削除", !sheet.deleteHeld) { act { delete() } } }
        if (sheet.whyNotDeleted.isNotEmpty()) Footnote(sheet.whyNotDeleted, Modifier.padding(horizontal = 24.dp))
        if (sheet.summary.isNotEmpty()) Part("番組内容", sheet.summary)
        for (text in sheet.details) Part("詳細", text)
        if (sheet.problem.isNotEmpty()) Problem(sheet.problem)
    }
    sheet?.asked?.let { asked ->
        // 削除する is held while the device works or a run is under way, as on iOS.
        AskDialog(asked, act = { act { confirmDelete(asked.key) } }, closeAsked = { act { closeAsked(asked.key) } },
                  actionEnabled = !sheet.actionHeld)
    }
}

/** Buttons side by side, wrapping to the next line where the sheet is narrow. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FlowRowOfButtons(content: @Composable () -> Unit) {
    FlowRow(Modifier.padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { content() }
}

// MARK: the sheets' rows

@Composable
internal fun Title(text: String) {
    Text(text, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp))
}

@Composable
private fun SectionHeading(text: String) {
    HorizontalDivider(Modifier.padding(top = 8.dp))
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
         modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 12.dp, bottom = 4.dp))
}

@Composable
private fun clear() = ListItemDefaults.colors(containerColor = Color.Transparent)

/** A label and its value, on the sheet's own ground. */
@Composable
private fun Value(label: String, value: String) {
    ListItem(headlineContent = { Text(label) }, trailingContent = { Text(value, style = MaterialTheme.typography.bodyLarge) },
             colors = clear(), modifier = Modifier.padding(horizontal = 8.dp))
}

/** A label and a choice, which opens what it can be changed to. */
@Composable
private fun Pick(label: String, options: List<Labelled>, chosen: String, enabled: Boolean, pick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    ListItem(headlineContent = { Text(label) }, colors = clear(), modifier = Modifier.padding(horizontal = 8.dp), trailingContent = {
        Box {
            TextButton(onClick = { open = true }, enabled = enabled) {
                Text(options.firstOrNull { it.code == chosen }?.label ?: chosen)
                Icon(Icons.Default.ArrowDropDown, contentDescription = null)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                for (option in options) {
                    DropdownMenuItem(text = { Text(option.label) }, onClick = {
                        open = false
                        pick(option.code)
                    }, leadingIcon = {
                        if (option.code == chosen) Icon(Icons.Default.Check, contentDescription = null) else Spacer(Modifier.width(24.dp))
                    })
                }
            }
        }
    })
}

/** A request of the sheet's own under way, or the sheet being read. */
@Composable
internal fun Working(line: String) {
    Row(Modifier.padding(horizontal = 24.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
        if (line.isNotEmpty()) Text(line, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
internal fun Problem(text: String) {
    Text(text, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium,
         modifier = Modifier.padding(horizontal = 24.dp, vertical = 4.dp))
}

@Composable
private fun Destructive(label: String, enabled: Boolean, press: () -> Unit) {
    TextButton(onClick = press, enabled = enabled, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
        Text(label)
    }
}

@Composable
private fun Part(heading: String, body: String) {
    Column(Modifier.padding(horizontal = 24.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(heading, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        Text(body, style = MaterialTheme.typography.bodyMedium)
    }
}
