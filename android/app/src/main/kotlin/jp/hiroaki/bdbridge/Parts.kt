package jp.hiroaki.bdbridge

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material.icons.outlined.TheaterComedy
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
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

/** The top app bars' overflow menu: what is not yet on a screen of its own. */
@Composable
fun AppMenu(search: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Default.MoreVert, contentDescription = "その他") }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text("レコーダーを探す") }, onClick = {
                open = false
                search()
            })
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

@Composable
fun Footnote(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = modifier)
}
