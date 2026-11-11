package jp.hiroaki.bdbridge

import android.graphics.BitmapFactory
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp

/**
 * The search, as the iOS app's 検索: one box over the programmes still to come, what is set to record and what is
 * recorded. The box is the top app bar, with the three it searches under it as chips, on the screen from the start;
 * what it finds opens the same sheets as the lists it is found in. What is shown, and when it is searched, are the
 * model's (`SearchState`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchScreen() {
    val shown = RecBridge.search.collectAsState().value ?: return
    // While the screen is on, Swift searches the guide a moment after the words change, and reads the lists.
    DisposableEffect(Unit) {
        RecBridge.searchShown(true)
        onDispose { RecBridge.searchShown(false) }
    }
    var programme by remember { mutableStateOf<FoundProgramme?>(null) }
    var reservation by remember { mutableStateOf<ReservationItem?>(null) }
    var recording by remember { mutableStateOf<RecordingItem?>(null) }
    programme?.let { found ->
        ProgrammeSheetView(found.row, starts = "${found.day} ${found.row.time}",
                           open = { RecBridge.openFoundProgramme(found.row.id) }) { programme = null }
    }
    reservation?.let { row -> ReservationSheetView(row.title, open = { RecBridge.openFoundReservation(row.id) }) { reservation = null } }
    recording?.let { row -> TitleSheetView(row, open = { RecBridge.openFoundRecording(row.id) }) { recording = null } }
    Scaffold(topBar = {
        Column {
            TopAppBar(title = { SearchBox(shown.prompt) })
            Scopes(shown)
            StripBar()
        }
    }) { padding ->
        // Above the keyboard, so that what is said of the words typed is not under it: by what the keyboard takes
        // beyond the bars the padding already answers for.
        Box(Modifier.padding(padding).consumeWindowInsets(padding).imePadding().fillMaxSize()) {
            when (shown.shows) {
                "waiting" -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                "results" -> Column {
                    // How many, which the iOS screen says under its title: over the results here, where it stays as
                    // they scroll.
                    Surface(color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
                        Text(shown.countLine, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                             modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                    }
                    when (shown.scope) {
                        "guide" -> FoundProgrammes(shown) { programme = it }
                        "reservations" -> LazyColumn(Modifier.fillMaxSize(), state = listKeptAtItsTop()) {
                            items(shown.reservations, key = { it.id }) { row -> ReservationRow(row) { reservation = row } }
                        }
                        else -> LazyColumn(Modifier.fillMaxSize(), state = listKeptAtItsTop()) {
                            items(shown.recordings, key = { it.id }) { row -> RecordingRow(row) { recording = row } }
                        }
                    }
                }
                else -> Unavailable(Icons.Default.Search, shown.title, shown.detail)
            }
        }
    }
}

/**
 * A list's place, kept at the top while it is at the top: a list keeps its place by its first row, and with other
 * words in the box that row may be found again further down, the better matches then out of sight above it. A list
 * scrolled keeps its place, as it does when a row is deleted from its sheet.
 */
@Composable
private fun listKeptAtItsTop(): LazyListState {
    val state = rememberLazyListState()
    Snapshot.withoutReadObservation {
        if (state.firstVisibleItemIndex == 0 && state.firstVisibleItemScrollOffset == 0) state.requestScrollToItem(0)
    }
    return state
}

/** The box, drawn from what was typed as it is typed, with what the scope searches said in it while it is empty. */
@Composable
private fun SearchBox(prompt: String) {
    val keyboard = LocalSoftwareKeyboardController.current
    val field = RecBridge.searchField
    TextField(
        value = field.typed, onValueChange = { field.type(it) }, singleLine = true, shape = CircleShape,
        placeholder = { Text(prompt, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
        trailingIcon = {
            if (field.typed.isNotEmpty()) {
                IconButton(onClick = { field.type("") }) { Icon(Icons.Default.Close, contentDescription = "消去") }
            }
        },
        colors = TextFieldDefaults.colors(focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { keyboard?.hide() }),
        modifier = Modifier.fillMaxWidth().padding(end = 16.dp),
    )
}

/** 番組表, 予約 and 録画, the one searched ticked. */
@Composable
private fun Scopes(shown: Search) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        for (scope in shown.scopes) {
            val chosen = scope.code == shown.scope
            FilterChip(selected = chosen, onClick = { RecBridge.searchScope(scope.code) }, label = { Text(scope.label) },
                       leadingIcon = if (chosen) ({ Icon(Icons.Default.Check, contentDescription = null) }) else null)
        }
    }
}

/**
 * The programmes found, each with its day, since they are of every day of the guide; one found only in its details
 * says the words found under 詳細, as the iOS row does.
 */
@Composable
private fun FoundProgrammes(shown: Search, open: (FoundProgramme) -> Unit) {
    val now = minuteNow()
    val logos = remember(shown.logos) {
        shown.logos.mapValues { (_, image) -> BitmapFactory.decodeByteArray(image, 0, image.size)?.asImageBitmap() }
    }
    val strong = SpanStyle(color = MaterialTheme.colorScheme.onSurface, fontWeight = FontWeight.SemiBold)
    LazyColumn(Modifier.fillMaxSize(), state = listKeptAtItsTop()) {
        if (shown.moreLine.isNotEmpty()) {
            item(key = "more") { Footnote(shown.moreLine, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
        }
        items(shown.programmes, key = { it.row.id }) { found ->
            val words = if (!found.hasSnippet) null else buildAnnotatedString {
                append("詳細：" + found.before)
                withStyle(strong) { append(found.match) }
                append(found.after)
            }
            ProgrammeRow(found.row, logos[found.logo], now, day = found.day, found = words) { open(found) }
            HorizontalDivider()
        }
    }
}
