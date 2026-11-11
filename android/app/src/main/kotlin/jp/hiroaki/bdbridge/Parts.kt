package jp.hiroaki.bdbridge

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Router
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material.icons.outlined.TheaterComedy
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** A title and what is said under it, in the middle of the screen, with what is offered: Material's empty state. */
@Composable
fun Unavailable(icon: ImageVector, title: String, detail: String, actions: @Composable () -> Unit = {}) {
    Column(Modifier.fillMaxSize().padding(32.dp),
           verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
           horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, contentDescription = null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        if (detail.isNotEmpty()) {
            Text(detail, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
                 color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        actions()
    }
}

/** What a screen says in place of its list with no recorder to talk to, in the iOS app's four cases (`NoRecorderView`). */
@Composable
fun NoRecorderView(icon: ImageVector, said: NoRecorder, search: () -> Unit) {
    val scope = rememberCoroutineScope()
    Unavailable(icon, said.title, said.detail) {
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

/** A short word marking a row -- 放送中, 予約, 録画中 -- on a tinted ground. */
@Composable
fun Mark(text: String, container: Color, content: Color, modifier: Modifier = Modifier) {
    Surface(modifier, shape = MaterialTheme.shapes.extraSmall, color = container, contentColor = content) {
        Text(text, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp))
    }
}

/** A title with a smaller line under it, for a top app bar that says how many. */
@Composable
fun TitleWithSubtitle(title: String, subtitle: String) {
    Column {
        Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (subtitle.isNotEmpty()) {
            Text(subtitle, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** What a search came to, with the likely causes under it when it found nothing, in the tutorial and the settings. */
@Composable
fun SearchOutcome(outcome: String, failed: Boolean, note: String, causes: List<String>) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(outcome, style = MaterialTheme.typography.bodyMedium,
             color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        if (note.isNotEmpty()) Footnote(note)
        if (causes.isNotEmpty()) {
            Text("考えられる原因", style = MaterialTheme.typography.labelMedium)
            for (cause in causes) Footnote("・$cause")
        }
    }
}

/** The recorders a search found, in the tutorial and the settings: the one in use says so, any other connects. */
@Composable
fun FoundRecordersCard(recorders: List<FoundRecorder>, canChoose: Boolean, choose: (String) -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Text("見つかったレコーダー", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
             modifier = Modifier.padding(start = 16.dp, top = 12.dp))
        recorders.forEachIndexed { index, found ->
            if (index > 0) HorizontalDivider()
            ListItem(
                leadingContent = { Icon(Icons.Outlined.Router, contentDescription = null) },
                headlineContent = { Text(found.name) },
                supportingContent = { Text(found.details) },
                trailingContent = {
                    if (found.inUse) Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Check, contentDescription = null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                        Text("使用中", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelLarge)
                    } else {
                        Text("接続する", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelLarge)
                    }
                },
                modifier = Modifier.clickable(enabled = canChoose) { choose(found.host) },
            )
        }
    }
}

/**
 * The strip under every screen's top app bar (`RecorderActivityBar` on iOS): what the app is doing with a device, or
 * what the reader is to know of now, one thing at a time, as the model chooses it.
 */
@Composable
fun StripBar() {
    val strip = RecBridge.strip.collectAsState().value
    val scope = rememberCoroutineScope()
    // The last line shown, kept while the strip slides away, so that it does not empty itself as it goes.
    var last by remember { mutableStateOf<Strip?>(null) }
    // 登録's sheet, which registers with the television added again.
    var registering by remember { mutableStateOf<TVSheetRequest?>(null) }
    registering?.let { request -> TVRegisterSheetView(request) { registering = null } }
    if (strip != null && strip.kind.isNotEmpty()) last = strip
    AnimatedVisibility(visible = strip != null && strip.kind.isNotEmpty()) {
        val line = last ?: return@AnimatedVisibility
        Column {
            Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (line.kind == "busy") {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(stripIcon(line.kind), contentDescription = null, Modifier.size(18.dp),
                             tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(line.text, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f).padding(vertical = 8.dp),
                         maxLines = if (line.inFull) Int.MAX_VALUE else 3, overflow = TextOverflow.Ellipsis)
                    when (line.action) {
                        "close" -> IconButton(onClick = { scope.launch { RecBridge.act { it.strip.close() } } }) {
                            Icon(Icons.Default.Close, contentDescription = "閉じる", Modifier.size(18.dp))
                        }
                        "leaveDemo" -> TextButton(onClick = { scope.launch { RecBridge.act { it.devices.leaveDemo() } } },
                                                  enabled = line.actionEnabled) { Text("終了") }
                        "reconnect" -> TextButton(onClick = { scope.launch { RecBridge.act { it.strip.reconnect() } } },
                                                  enabled = line.actionEnabled) { Text("再接続") }
                        "registerTV" -> TextButton(onClick = {
                            registering = TVSheetRequest("", connectAtOnce = false, again = true)
                        }) { Text("登録") }
                        "reconnectTV" -> TextButton(onClick = { scope.launch { RecBridge.act { it.strip.reconnectTV() } } },
                                                    enabled = line.actionEnabled) { Text("再接続") }
                    }
                }
            }
            HorizontalDivider()
        }
    }
}

private fun stripIcon(kind: String): ImageVector = when (kind) {
    "anotherTookOver" -> Icons.Outlined.SwapHoriz
    "report" -> Icons.Outlined.History
    "demo" -> Icons.Outlined.TheaterComedy
    "blocked" -> Icons.Outlined.Shield
    "recorderGaveUp" -> Icons.Outlined.WifiOff
    "tvDiskAway" -> Icons.Outlined.Storage
    else -> Icons.Outlined.Tv
}

/** The minute it is now, in seconds since 1970, turning over each minute so that what is on air is marked as it starts. */
@Composable
fun minuteNow(): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis() / 1000) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(60_000 - System.currentTimeMillis() % 60_000)
            now = System.currentTimeMillis() / 1000
        }
    }
    return now
}

/** What a row's swipe does: its word, on its ground, and whether it does anything now. */
class SwipeAction(val label: String, val container: Color, val content: Color, val enabled: Boolean, val act: () -> Unit)

/**
 * A row with what a swipe either way asks for, as an iOS row's swipe actions: `toTheRight` under a swipe to the
 * right, `toTheLeft` under one to the left. The row never goes with the swipe -- it comes back, and what was asked
 * for is asked first or answered by the device, the row going when the list is read again -- and a swipe does nothing
 * while its action is held. The same actions are offered by name to a screen reader.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SwipeActions(toTheRight: SwipeAction?, toTheLeft: SwipeAction?, content: @Composable () -> Unit) {
    // The state keeps the first lambda it was made with: what the row offers now is read through these.
    val right by rememberUpdatedState(toTheRight)
    val left by rememberUpdatedState(toTheLeft)
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.StartToEnd -> right?.takeIf { it.enabled }?.act?.invoke()
            SwipeToDismissBoxValue.EndToStart -> left?.takeIf { it.enabled }?.act?.invoke()
            SwipeToDismissBoxValue.Settled -> {}
        }
        false
    })
    val named = listOfNotNull(toTheRight, toTheLeft).filter { it.enabled }.map { action ->
        CustomAccessibilityAction(action.label) {
            action.act()
            true
        }
    }
    SwipeToDismissBox(
        state = state, enableDismissFromStartToEnd = toTheRight != null, enableDismissFromEndToStart = toTheLeft != null,
        modifier = Modifier.semantics { customActions = named },
        backgroundContent = {
            val toRight = state.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            val action = (if (toRight) toTheRight else toTheLeft) ?: return@SwipeToDismissBox
            val (container, onContainer) = if (action.enabled) action.container to action.content
                                           else MaterialTheme.colorScheme.surfaceContainerHighest to MaterialTheme.colorScheme.onSurfaceVariant
            Box(Modifier.fillMaxSize().background(container).padding(horizontal = 20.dp),
                contentAlignment = if (toRight) Alignment.CenterStart else Alignment.CenterEnd) {
                Text(action.label, color = onContainer, style = MaterialTheme.typography.labelLarge)
            }
        },
    ) { Column { content() } }
}

@Composable
fun Footnote(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = modifier)
}
