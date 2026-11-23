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
import androidx.compose.runtime.MutableState
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

// The programme's sheet, the reservation's and the recording's, as the iOS sheets lay them out: what each holds,
// offers, holds back and says, and what each press does, are the model's, through the sheets' windows
// (core/.../Sheets.swift). A sheet opens at once with what the row it was opened from already says, and the rest comes
// in as its window is read. The same content is a bottom sheet, or on a wide screen the pane beside the list, over the
// one window the screen opened for what is open (`rememberOpened`).

/** A sheet's window as it is opened: the window once it has come, and whether there was none to open. */
class Opened<H : RecBridge.Sheet<*>> internal constructor() {
    var handle by mutableStateOf<H?>(null)
        internal set
    /** There was no window to open, the row having gone since it was tapped. */
    var missing by mutableStateOf(false)
        internal set
}

/**
 * A sheet's window, opened as what it is for is opened and closed as that goes, by `key`: another key -- another row
 * taking the place of the one open beside the list -- closes the first one's window, whose presses would otherwise go
 * on to the row before, and opens its own. The opening runs where what is open going does not cancel it, and a window
 * that comes back for what has gone already is closed at once: left open, it would go on following the model, and
 * asking the recorder, for nobody.
 *
 * What is opened from a list has its window opened by the screen, beside the screen's own state of what is open, and
 * handed to whichever form shows it, the sheet or the pane: a turn across 840 dp changes the form and not the window,
 * so its picks, its question, a request of its own out and the hold on it are as they were.
 */
@Composable
fun <H : RecBridge.Sheet<*>> rememberOpened(key: Any, open: suspend () -> H?): Opened<H> {
    val opened = remember(key) { Opened<H>() }
    DisposableEffect(key) {
        var gone = false
        RecBridge.launch {
            val window = open()
            when {
                gone -> window?.close()
                window == null -> opened.missing = true
                else -> opened.handle = window
            }
        }
        onDispose {
            gone = true
            opened.handle?.close()
        }
    }
    return opened
}

/**
 * A programme opened from a list, as the screen holds it: its window, and what 予約を変更する puts up over it -- the
 * device whose reservation's own sheet is up, and that sheet's window -- each kept with the programme for the same
 * reason (`rememberOpened`).
 */
class ProgrammeOpened(val programme: Opened<RecBridge.ProgrammeSheetHandle>, device: MutableState<String?>,
                      val change: Opened<RecBridge.ReservationSheetHandle>?) {
    /** The device whose reservation's own sheet is up over the programme's, or none. */
    var editing by device
}

/** A programme's window, opened by the screen for the programme `id` (`rememberOpened`), and 予約を変更する's over it. */
@Composable
fun rememberProgramme(id: String, open: suspend () -> RecBridge.ProgrammeSheetHandle?): ProgrammeOpened {
    val programme = rememberOpened(id, open)
    // By the programme: on the pane, another programme takes the place of this one, and must not come up with this
    // one's 予約を変更する.
    val editing = remember(id) { mutableStateOf<String?>(null) }
    val handle = programme.handle
    val change = editing.value?.let { device ->
        handle?.let { opened -> rememberOpened(id to device) { opened.change(device) } }
    }
    return remember(programme, change) { ProgrammeOpened(programme, editing, change) }
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
 * Where a sheet's content goes: a bottom sheet over the list it was opened from, or the pane beside the list on a wide
 * screen (`inPane`, Panes.kt). The pane is cleared as the sheet would close (`done`), and also once `gone`: the row it
 * was opened for is no longer on the list -- another day, a filter, deleted from the list beside it -- or there was no
 * window to open for it, and nothing of its own is out or up. A sheet covers the list, so its row cannot go that way
 * while it is open; a pane left with it would show what is not listed, or wait for ever for a window.
 */
@Composable
internal fun SheetOrPane(inPane: Boolean, held: Boolean, done: Boolean, gone: Boolean, close: () -> Unit,
                         content: @Composable () -> Unit) {
    if (inPane) DetailPane(held, leaving = done || gone, close = close, content = content)
    else HeldSheet(held, done, close, content)
}

/**
 * The one question or answer up at a time: the button that does something, if any, and the one that closes. A
 * question is answered by its buttons, as an iOS alert is, and not put away by a touch beside it; the back key is
 * its closing button. An answer with OK alone goes either way.
 */
@Composable
internal fun AskDialog(asked: Asked, act: () -> Unit, closeAsked: () -> Unit, actionEnabled: Boolean = true) {
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

/**
 * The programme's sheet: what it is, the reservations of it, and 録画予約 where it is offered, over the windows the
 * screen opened for it (`rememberProgramme`). On the pane (`inPane`), `listed` says whether the list beside it still
 * has the programme.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProgrammeSheetView(row: Programme, opened: ProgrammeOpened, inPane: Boolean = false, listed: Boolean = true,
                       close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val handle = opened.programme.handle
    val sheet = handle?.let { it.shown.collectAsState().value }
    val act = { work: suspend RecBridge.ProgrammeSheetHandle.() -> Unit -> handle?.let { scope.launch { it.work() } }; Unit }
    val free = sheet != null && sheet.asking.isEmpty()
    val held = sheet?.held ?: false
    // Up over it, the reservation's own sheet counts as its own: it may have a request out.
    val gone = (opened.programme.missing || !listed) && !held && sheet?.asked == null && opened.editing == null
    val words = RecBridge.sheetWords

    SheetOrPane(inPane, held, done = sheet?.done ?: false, gone = gone, close = close) {
        Title(sheet?.title ?: row.title)
        // Not on the pane, under the strip that says it already.
        if (!inPane) sheet?.waking?.takeIf { it.isNotEmpty() }?.let { Working(it) }
        Value(words.station, sheet?.station ?: row.station)
        Value(words.starts, sheet?.starts ?: row.dated)
        Value(words.length, sheet?.length ?: row.length)
        (sheet?.genre ?: row.genre).takeIf { it.isNotEmpty() }?.let { Value(words.genre, it) }
        if (sheet == null) {
            Working("")
        } else {
            sheet.recorders?.let { held ->
                HeldSection(held, sheet, enabled = free, change = { opened.editing = "recorder" }, delete = { act { delete("recorder") } })
            }
            sheet.televisions?.let { held ->
                HeldSection(held, sheet, enabled = free, change = { opened.editing = "tv" }, delete = { act { delete("tv") } })
            }
            sheet.waitingForTheRecorder?.let { waiting ->
                WaitingSection(waiting, sheet, free, sendAgain = { act { sendAgain("recorder") } }, delete = { act { deleteWaiting("recorder") } })
            }
            sheet.waitingForTheTelevision?.let { waiting ->
                WaitingSection(waiting, sheet, free, sendAgain = { act { sendAgain("tv") } }, delete = { act { deleteWaiting("tv") } })
            }
            if (sheet.asking.isNotEmpty()) Working(sheet.asking)
            if (sheet.offer.isNotEmpty()) Offer(sheet, free, act)
        }
        (sheet?.summary ?: row.summary).takeIf { it.isNotEmpty() }?.let { Part(words.summaryHeading, it) }
        sheet?.extended?.takeIf { it.isNotEmpty() }?.let { Part(words.detailsHeading, it) }
        sheet?.problem?.takeIf { it.isNotEmpty() }?.let { Problem(it) }
    }
    sheet?.asked?.let { asked -> AskDialog(asked, act = { act { act(asked.key) } }, closeAsked = { act { closeAsked(asked.key) } }) }
    // A sheet over the sheet or the pane, as on iOS: it is the reservation's own.
    opened.change?.let { change ->
        ReservationSheetView(row.title, change, close = {
            opened.editing = null
            handle?.let { programme -> scope.launch { programme.changeClosed() } }
        })
    }
}

/** 録画予約: where it goes, the recorder's disk, the mode, the repeat, what it would clash with, and the button. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Offer(sheet: ProgrammeSheetScreen, free: Boolean,
                  act: (suspend RecBridge.ProgrammeSheetHandle.() -> Unit) -> Unit) {
    val words = RecBridge.sheetWords
    SectionHeading(sheet.reserveHeading)
    if (sheet.destinations.isNotEmpty()) {
        ListItem(headlineContent = { Text(sheet.destinationLabel) }, colors = clear(), trailingContent = {
            SingleChoiceSegmentedButtonRow {
                sheet.destinations.forEachIndexed { index, choice ->
                    SegmentedButton(selected = sheet.device == choice.code, enabled = free,
                                    onClick = { act { chooseDevice(choice.code) } },
                                    shape = SegmentedButtonDefaults.itemShape(index, sheet.destinations.size)) { Text(choice.label) }
                }
            }
        })
    } else if (sheet.destinationAlone.isNotEmpty()) {
        Value(sheet.destinationLabel, sheet.destinationAlone)
    }
    if (sheet.disks.isNotEmpty()) Pick(words.disk, sheet.disks, sheet.disk, free) { act { chooseDisk(it) } }
    else if (sheet.diskAlone.isNotEmpty()) Value(words.disk, sheet.diskAlone)
    if (sheet.qualities.isNotEmpty()) Pick(words.quality, sheet.qualities, sheet.quality, free) { act { chooseQuality(it) } }
    else Value(words.quality, sheet.qualityAlone)
    Pick(words.repeating, sheet.repeats, sheet.repeating, free) { act { chooseRepeat(it) } }
    if (sheet.offer == "recorder") Clashes(sheet)
    Button(onClick = { act { reserve() } }, enabled = free && !sheet.reserveHeld,
           modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp)) { Text(sheet.reserveLabel) }
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

/** A device's reservation of the programme, with the way to change it and to delete it, in the sheet's words. */
@Composable
private fun HeldSection(held: HeldReservation, sheet: ProgrammeSheetScreen, enabled: Boolean, change: () -> Unit,
                        delete: () -> Unit) {
    val words = RecBridge.sheetWords
    SectionHeading(held.heading)
    if (held.quality.isNotEmpty()) Value(words.quality, held.quality)
    Value(words.repeating, held.repeating)
    if (held.disk.isNotEmpty()) Value(words.disk, held.disk)
    if (held.recording) Problem(words.recordingLine)
    Row(Modifier.padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (held.offersChanging) OutlinedButton(onClick = change, enabled = enabled && !held.changeHeld) { Text(sheet.changeLabel) }
        Destructive(words.deleteReservationLabel, enabled && !held.deleteHeld, delete)
    }
    if (held.problem.isNotEmpty()) Problem(held.problem)
}

/**
 * A reservation waiting on this device: what was asked for, and what the device said if it refused it, in the sheet's
 * words.
 */
@Composable
private fun WaitingSection(waiting: WaitingReservation, sheet: ProgrammeSheetScreen, enabled: Boolean,
                           sendAgain: () -> Unit, delete: () -> Unit) {
    val words = RecBridge.sheetWords
    SectionHeading(waiting.heading)
    Value(words.quality, waiting.quality)
    Value(words.repeating, waiting.repeating)
    if (waiting.disk.isNotEmpty()) Value(words.disk, waiting.disk)
    if (waiting.problem.isNotEmpty()) Problem(waiting.problem) else Footnote(waiting.notYet, Modifier.padding(horizontal = 24.dp))
    Row(Modifier.padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (waiting.problem.isNotEmpty()) {
            OutlinedButton(onClick = sendAgain, enabled = enabled && !waiting.sendAgainHeld) { Text(sheet.sendAgainLabel) }
        }
        Destructive(sheet.deleteWaitingLabel, enabled && !waiting.deleteHeld, delete)
    }
}

/**
 * The reservation's sheet: the reservation as the device that holds it has it, what can still be changed of it and
 * the change to send, and its delete. Opened from the reservations' list, or from a programme's sheet over it, over
 * the window opened for it there, by the reservation (`rememberOpened`).
 */
@Composable
fun ReservationSheetView(title: String, window: Opened<RecBridge.ReservationSheetHandle>, inPane: Boolean = false,
                         listed: Boolean = true, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val handle = window.handle
    val sheet = handle?.let { it.shown.collectAsState().value }
    val act = { work: suspend RecBridge.ReservationSheetHandle.() -> Unit -> handle?.let { scope.launch { it.work() } }; Unit }
    val free = sheet != null && sheet.asking.isEmpty()
    val held = sheet?.asking?.isNotEmpty() ?: false
    val words = RecBridge.sheetWords

    SheetOrPane(inPane, held, done = sheet?.done ?: false,
                gone = (window.missing || !listed) && !held && sheet?.asked == null, close = close) {
        Title(sheet?.title ?: title)
        if (sheet == null) return@SheetOrPane Working("")
        // Not on the pane, under the strip that says it already.
        if (!inPane && sheet.waking.isNotEmpty()) Working(sheet.waking)
        Value(words.station, sheet.station)
        Value(words.starts, sheet.starts)
        Value(words.length, sheet.length)
        if (sheet.settled) {
            if (sheet.qualityValue.isNotEmpty()) Value(words.quality, sheet.qualityValue)
            Value(words.repeating, sheet.repeatValue)
        } else {
            if (sheet.qualities.isNotEmpty()) Pick(words.quality, sheet.qualities, sheet.quality, free) { act { chooseQuality(it) } }
            else if (sheet.qualityValue.isNotEmpty()) Value(words.quality, sheet.qualityValue)
            Pick(words.repeating, sheet.repeats, sheet.repeating, free) { act { chooseRepeat(it) } }
        }
        if (sheet.disks.isNotEmpty()) Pick(words.disk, sheet.disks, sheet.disk, free) { act { chooseDisk(it) } }
        else if (sheet.diskAlone.isNotEmpty()) Value(words.disk, sheet.diskAlone)
        if (sheet.follows.isNotEmpty()) Value(sheet.followsLabel, sheet.follows)
        if (sheet.madeBy.isNotEmpty()) Value(sheet.madeByLabel, sheet.madeBy)
        if (sheet.size.isNotEmpty()) Value(sheet.sizeLabel, sheet.size)
        if (sheet.recording) Problem(words.recordingLine)
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
        if (sheet.summary.isNotEmpty()) Part(words.summaryHeading, sheet.summary)
        if (sheet.extended.isNotEmpty()) Part(words.detailsHeading, sheet.extended)
        if (sheet.asking.isNotEmpty()) Working(sheet.asking)
        if (sheet.changed) {
            Button(onClick = { act { sendTheChange() } }, enabled = free && !sheet.buttonsHeld,
                   modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 4.dp)) { Text(sheet.changeLabel) }
            Footnote(sheet.changeFooter, Modifier.padding(horizontal = 24.dp))
        }
        Box(Modifier.padding(horizontal = 24.dp)) {
            Destructive(words.deleteReservationLabel, free && !sheet.buttonsHeld) { act { delete() } }
        }
        if (sheet.problem.isNotEmpty()) Problem(sheet.problem)
    }
    sheet?.asked?.let { asked ->
        AskDialog(asked, act = { act { confirmDelete(asked.key) } }, closeAsked = { act { closeAsked(asked.key) } })
    }
}

/**
 * The recording's sheet: what it is, playing it on the television, protecting it, and deleting it, as the iOS sheet
 * lays them out, over the window opened for it where it was opened from (`rememberOpened`). It opens at once with what
 * the row says. On the pane, `listed` says whether the list beside it still has the recording.
 */
@Composable
fun TitleSheetView(row: RecordingItem, window: Opened<RecBridge.TitleSheetHandle>, inPane: Boolean = false,
                   listed: Boolean = true, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val handle = window.handle
    val sheet = handle?.let { it.shown.collectAsState().value }
    val act = { work: suspend RecBridge.TitleSheetHandle.() -> Unit -> handle?.let { scope.launch { it.work() } }; Unit }
    val held = sheet?.asking ?: false
    val words = RecBridge.sheetWords

    SheetOrPane(inPane, held, done = sheet?.done ?: false,
                gone = (window.missing || !listed) && !held && sheet?.asked == null, close = close) {
        Title(sheet?.title ?: row.title)
        // Not on the pane, under the strip that says it already. The strip, as on iOS, rather than the waking alone:
        // turning the recorder on to play takes as long as waking it, and the strip says how long it has been.
        if (!inPane) StripBar(inSheet = true)
        if (sheet == null) {
            Footnote(row.details, Modifier.padding(horizontal = 24.dp))
            return@SheetOrPane Working("")
        }
        Value(words.station, sheet.station)
        Value(sheet.recordedLabel, sheet.recorded)
        if (sheet.length.isNotEmpty()) Value(words.length, sheet.length)
        if (sheet.size.isNotEmpty()) Value(sheet.sizeLabel, sheet.size)
        if (sheet.quality.isNotEmpty()) Value(words.quality, sheet.quality)
        if (sheet.disk.isNotEmpty()) Value(words.disk, sheet.disk)
        Value(sheet.viewingLabel, sheet.viewing)
        if (sheet.genre.isNotEmpty()) Value(words.genre, sheet.genre)
        if (sheet.offersPlayback) {
            SectionHeading(sheet.playbackHeading)
            FlowRowOfButtons {
                OutlinedButton(onClick = { act { play("play") } }, enabled = !sheet.playHeld) {
                    Icon(Icons.Default.PlayArrow, contentDescription = null, Modifier.size(18.dp))
                    Text(" " + sheet.playLabel)
                }
                OutlinedButton(onClick = { act { play("pause") } }, enabled = !sheet.playbackHeld) {
                    Icon(Icons.Default.Pause, contentDescription = null, Modifier.size(18.dp))
                    Text(" " + sheet.pauseLabel)
                }
                OutlinedButton(onClick = { act { play("stop") } }, enabled = !sheet.playbackHeld) {
                    Icon(Icons.Default.Stop, contentDescription = null, Modifier.size(18.dp))
                    Text(" " + sheet.stopLabel)
                }
                if (sheet.offersPower) {
                    OutlinedButton(onClick = { act { powerOn() } }, enabled = !sheet.playbackHeld) {
                        Icon(Icons.Default.PowerSettingsNew, contentDescription = null, Modifier.size(18.dp),
                             tint = LocalMarks.current.onReserved)
                        Text(" " + sheet.powerLabel, color = LocalMarks.current.onReserved)
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
        Box(Modifier.padding(horizontal = 24.dp)) { Destructive(sheet.deleteLabel, !sheet.deleteHeld) { act { delete() } } }
        if (sheet.whyNotDeleted.isNotEmpty()) Footnote(sheet.whyNotDeleted, Modifier.padding(horizontal = 24.dp))
        if (sheet.summary.isNotEmpty()) Part(words.summaryHeading, sheet.summary)
        for (text in sheet.details) Part(words.detailsHeading, text)
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
internal fun Pick(label: String, options: List<Labelled>, chosen: String, enabled: Boolean, pick: (String) -> Unit) {
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
