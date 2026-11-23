package jp.hiroaki.bdbridge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItemColors
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

// A wide screen's two panes, which the iOS app, an iPhone's alone, has no form of: the list on the left and what was
// opened from it on the right, where a phone opens a sheet over the list. The sheet's content is the same in both
// (`SheetOrPane`, Sheets.kt); what changes is what a sheet has by being modal, which the pane has to keep by rule.

/**
 * Whether the screens with a list show what is opened from it beside it: a window 840 dp wide or more, Material's
 * expanded width, as the window is now, so that turning the device changes the form.
 */
@Composable
internal fun twoPanes(): Boolean = LocalConfiguration.current.screenWidthDp >= 840

/** How wide the pane beside the list is: about a phone's width, the width the sheets' content is laid out for. */
private val DetailWidth = 400.dp

/**
 * Whether what is open in the pane is held: a request of its own is out. It is the model's rule, the one by which the
 * same content on a sheet refuses to be put away (`held` of `ProgrammeSheetScreen`, `asking` of the reservation's and
 * the recording's), told here by the pane (`DetailPane`). One for the app, as one screen is on at a time. While it is
 * held, nothing that would replace or take away what is open is taken: another row, the list's and the top app bar's
 * controls, the navigation, the back key. A sheet gets that from covering them; beside a live list, whatever went
 * would take the request's answer with it, and it would be said nowhere.
 */
internal object PaneHold {
    var held by mutableStateOf(false)
}

/**
 * A screen's list and what is opened from it, in the screen's content under its top app bar and strip, which span
 * both. On a wide screen, the list, a divider and the pane of a fixed width beside it, saying `nothingOpened` while
 * nothing is open; elsewhere, and where `beside` is false, the list alone, as it was before there were two panes, and
 * what is opened goes over it as a sheet. The back key clears the pane first, and does nothing while it is held; with
 * no pane, it is not taken here at all.
 *
 * The list is at the same place in either, and only the divider and the pane come and go beside it: a turn across
 * 840 dp keeps all the list remembers -- where it is scrolled, the grid's position, a pull under way -- which a list
 * put somewhere else would make again.
 */
@Composable
internal fun ListAndDetail(opened: Boolean, close: () -> Unit, nothingOpened: @Composable () -> Unit,
                           detail: @Composable () -> Unit, beside: Boolean = true,
                           list: @Composable BoxScope.() -> Unit) {
    val wide = twoPanes() && beside
    BackHandler(enabled = wide && opened) { if (!PaneHold.held) close() }
    Row(Modifier.fillMaxSize()) {
        val held = wide && PaneHold.held
        Box(Modifier.weight(1f).fillMaxHeight().then(if (held) Modifier.clearAndSetSemantics {} else Modifier)) {
            list()
            if (held) Cover()
        }
        if (wide) {
            VerticalDivider()
            Surface(Modifier.width(DetailWidth).fillMaxHeight(), color = MaterialTheme.colorScheme.surfaceContainerLow) {
                if (opened) detail() else nothingOpened()
            }
        }
    }
}

/**
 * What beside the pane would replace or take away what is open in it -- the top app bar with the strip, the
 * navigation rail -- refused while that is held (`PaneHold`), as what is under a sheet's scrim is. Only with two panes:
 * elsewhere a sheet covers it. At the same place whatever the width, as the list is (`ListAndDetail`): a turn keeps
 * what is open in it, a menu or the search box's focus.
 */
@Composable
internal fun Refused(content: @Composable () -> Unit) {
    val held = twoPanes() && PaneHold.held
    Box(if (held) Modifier.clearAndSetSemantics {} else Modifier) {
        content()
        if (held) Cover()
    }
}

/**
 * Drawn over what is refused, taking every touch before it: what is under it is drawn as it is, with nothing dimmed
 * for a hold that is often over in a moment, and offers nothing to a screen reader while it is there.
 */
@Composable
private fun BoxScope.Cover() {
    Box(Modifier.matchParentSize().pointerInput(Unit) {
        awaitPointerEventScope {
            while (true) awaitPointerEvent().changes.forEach { it.consume() }
        }
    })
}

/**
 * What a sheet's content is put in on the pane: scrolled as on the sheet, the pane cleared when the sheet would close
 * -- its reservation made, its delete gone through -- or when what it was opened for has gone (`leaving`), and its
 * hold told to what is beside it.
 */
@Composable
internal fun DetailPane(held: Boolean, leaving: Boolean, close: () -> Unit, content: @Composable () -> Unit) {
    DisposableEffect(held) {
        PaneHold.held = held
        onDispose { PaneHold.held = false }
    }
    LaunchedEffect(leaving) { if (leaving) close() }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 12.dp, bottom = 24.dp)) {
        content()
    }
}

/** What the pane says while nothing is open: the screen's icon and one short sentence, quietly. */
@Composable
internal fun NothingOpened(icon: ImageVector, sentence: String) {
    Column(Modifier.fillMaxSize().padding(32.dp),
           verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
           horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, contentDescription = null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.outline)
        Text(sentence, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
             color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The sentences the pane says while nothing is open, Android's own: the iOS app has no pane to say them in. */
internal object NothingOpenedSays {
    const val programme = "番組を選ぶと、ここに表示されます"
    const val reservation = "予約を選ぶと、ここに表示されます"
    const val recording = "録画を選ぶと、ここに表示されます"
}

/**
 * The row whose detail is open beside the list, marked as Material marks the selected item of a list, and said to a
 * screen reader to be selected. Nothing on a row that is not, so that a phone's rows are as they were.
 */
@Composable
internal fun Modifier.openedBeside(opened: Boolean): Modifier =
    if (!opened) this else background(MaterialTheme.colorScheme.secondaryContainer).saidOpened(true)

/** The same for a block of the grid, which keeps its own ground: a ring round it. */
@Composable
internal fun Modifier.ringedBeside(opened: Boolean): Modifier =
    if (!opened) this else border(2.dp, MaterialTheme.colorScheme.primary, MaterialTheme.shapes.extraSmall)

/** A list item's colours for the row open beside the list, and the default for any other. */
@Composable
internal fun openedColors(opened: Boolean): ListItemColors =
    if (opened) ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
    else ListItemDefaults.colors()

/** Said to a screen reader of the list item open beside the list; nothing on any other. */
internal fun Modifier.saidOpened(opened: Boolean): Modifier = if (!opened) this else semantics { selected = true }
