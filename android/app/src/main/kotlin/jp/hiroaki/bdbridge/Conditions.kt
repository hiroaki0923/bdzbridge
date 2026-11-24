package jp.hiroaki.bdbridge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.RemoveCircleOutline
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

// The recorder's own keyword conditions (おまかせ・まる録), as the iOS screen and its form have them: what each says,
// offers and holds back is the model's (core/.../Conditions.swift).

/**
 * The conditions the recorder holds by itself, over the whole with the way back: made and removed from here, never
 * edited. A row swiped to the left asks to delete it; + opens the form for a new one, over this page. Pulled down,
 * the list is read again.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConditionsPage(close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val colors = MaterialTheme.colorScheme
    val words = RecBridge.conditionsWords
    val handle = rememberOpened(Unit) { RecBridge.openConditions() }.handle
    val shown = handle?.let { it.shown.collectAsState().value }
    val act = { work: suspend RecBridge.ConditionsHandle.() -> Unit -> handle?.let { scope.launch { it.work() } }; Unit }
    var adding by remember { mutableStateOf(false) }
    BackHandler(enabled = !adding, onBack = close)
    LaunchedEffect(handle, shown?.loadKey) { handle?.load() }
    shown?.asked?.let { asked ->
        AskDialog(asked, act = { act { act(asked.key) } }, closeAsked = { act { closeAsked(asked.key) } },
                  actionEnabled = !shown.actionHeld)
    }
    var pulling by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxSize()) {
        Scaffold(modifier = if (adding) Modifier.clearAndSetSemantics {} else Modifier, topBar = {
            Column {
                TopAppBar(
                    title = { Text(shown?.title ?: words.title) },
                    navigationIcon = { IconButton(onClick = close) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る") } },
                    actions = {
                        IconButton(onClick = { adding = true }, enabled = shown != null && !shown.addHeld) {
                            Icon(Icons.Default.Add, contentDescription = words.addLabel)
                        }
                    },
                )
                StripBar()
            }
        }) { padding ->
            Box(Modifier.padding(padding).fillMaxSize()) {
                if (shown == null) return@Box CircularProgressIndicator(Modifier.align(Alignment.Center))
                PullToRefreshBox(isRefreshing = pulling, onRefresh = {
                    pulling = true
                    scope.launch {
                        try {
                            handle.pullDown()
                        } finally {
                            pulling = false
                        }
                    }
                }, modifier = Modifier.fillMaxSize()) {
                    LazyColumn(Modifier.fillMaxSize()) {
                        when (shown.listSays) {
                            "failed" -> item(key = "says") {
                                ListItem(headlineContent = { Text(shown.saidTitle) },
                                         supportingContent = { Text(shown.saidDetail) })
                            }
                            "empty" -> item(key = "says") {
                                ListItem(headlineContent = { Text(shown.saidTitle, color = colors.onSurfaceVariant) })
                            }
                            "loading" -> item(key = "says") {
                                ListItem(leadingContent = { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) },
                                         headlineContent = { Text(shown.saidTitle, color = colors.onSurfaceVariant) })
                            }
                        }
                        items(shown.rows, key = { it.id }) { row ->
                            val delete = SwipeAction(RecBridge.listWords.deleteLabel, colors.errorContainer, colors.onErrorContainer, !shown.deleteHeld) {
                                act { delete(row.id) }
                            }
                            SwipeActions(toTheRight = null, toTheLeft = delete) {
                                ListItem(headlineContent = { Text(row.name) },
                                         supportingContent = { Text(row.details) })
                                HorizontalDivider()
                            }
                        }
                        item(key = "footer") { Footnote(shown.footer, Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) }
                    }
                }
            }
        }
        if (adding && handle != null) ConditionFormPage(handle) { adding = false }
    }
}

/**
 * The form for a new condition, over the conditions' page as a full-screen dialog: キャンセル and レコーダーに登録 in
 * its top app bar, the keywords and the words left out as rows, then the narrowing. It is held whole while the
 * registration is out, and closes once the condition is made.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConditionFormPage(page: RecBridge.ConditionsHandle, close: () -> Unit) {
    val words = RecBridge.conditionsWords
    val sheetWords = RecBridge.sheetWords
    val handle = rememberOpened(Unit) { page.newCondition() }.handle
    val form = handle?.let { it.shown.collectAsState().value }
    val held = form?.asking ?: false
    BackHandler(enabled = true) { if (!held) close() }
    LaunchedEffect(form?.done) { if (form?.done == true) close() }
    // What is typed, by its row, drawn as it is typed: the model's text is only what a row starts with. Let go of
    // whenever the form is not held, once its edits have all been answered: a keystroke made after レコーダーに登録
    // was pressed, and before the form was held, is turned down by the model, and the field then shows what the
    // model has, which is what the next press sends.
    val typed = remember { mutableStateMapOf<String, String>() }
    LaunchedEffect(held) { if (!held) typed.clear() }
    form?.failure?.takeIf { it.isNotEmpty() }?.let { said ->
        AlertDialog(onDismissRequest = { handle.failureClosed() },
                    confirmButton = { TextButton(onClick = { handle.failureClosed() }) { Text(sheetWords.okLabel) } },
                    title = { Text(words.failureTitle) }, text = { Text(said) })
    }
    Scaffold(topBar = {
        Column {
            TopAppBar(
                title = { Text(words.addLabel) },
                navigationIcon = {
                    IconButton(onClick = close, enabled = !held) { Icon(Icons.Default.Close, contentDescription = sheetWords.cancelLabel) }
                },
                actions = {
                    TextButton(onClick = { handle?.register() }, enabled = form != null && !form.registerHeld) {
                        Text(words.registerLabel)
                    }
                },
            )
            // The registration's line from the press, the waking and the wait for the USB slot.
            StripBar(inSheet = true)
        }
    }) { padding ->
        if (form == null || handle == null) {
            return@Scaffold Box(Modifier.padding(padding).fillMaxSize()) { CircularProgressIndicator(Modifier.align(Alignment.Center)) }
        }
        Column(Modifier.padding(padding).imePadding().fillMaxSize().verticalScroll(rememberScrollState())
                   .padding(vertical = 8.dp)) {
            Heading(words.keywordHeading)
            // Keyed by the row, so that a field, its focus and what is being composed in it go with its row when
            // another row is taken away.
            for (word in form.keywords) key(word.id) {
                WordField(text = typed[word.id] ?: word.text, placeholder = words.keywordPlaceholder, enabled = !held,
                          remove = if (form.mayRemoveKeyword) ({ handle.removeKeyword(word.id) }) else null) {
                    typed[word.id] = it
                    handle.typeKeyword(word.id, it)
                }
            }
            if (form.mayAddKeyword) AddButton(words.addKeywordLabel, !held) { handle.addKeyword() }
            Footnote(form.keywordFooter, Modifier.padding(horizontal = 16.dp, vertical = 4.dp))

            Heading(words.excludedHeading)
            for (word in form.excluded) key(word.id) {
                WordField(text = typed[word.id] ?: word.text, placeholder = words.excludedPlaceholder, enabled = !held,
                          remove = { handle.removeExclusion(word.id) }) {
                    typed[word.id] = it
                    handle.typeExclusion(word.id, it)
                }
            }
            if (form.mayAddExclusion) AddButton(words.addExclusionLabel, !held) { handle.addExclusion() }
            if (form.asksHowToCombine) Pick(words.logicLabel, form.logics, form.logic, !held) { handle.chooseLogic(it) }
            Footnote(form.excludedFooter, Modifier.padding(horizontal = 16.dp, vertical = 4.dp))

            Heading(words.narrowingHeading)
            Pick(sheetWords.genre, form.genres, form.genre, !held) { handle.chooseGenre(it) }
            if (form.subGenres.isNotEmpty()) Pick(words.subGenreLabel, form.subGenres, form.subGenre, !held) { handle.chooseSubGenre(it) }
            Pick(words.scopeLabel, form.scopes, form.scope, !held) { handle.chooseScope(it) }
            Pick(words.timeLabel, form.times, form.time, !held) { handle.chooseTime(it) }
            Pick(sheetWords.quality, form.qualities, form.quality, !held) { handle.chooseQuality(it) }
            if (form.disks.isNotEmpty()) {
                Pick(sheetWords.disk, form.disks, form.disk, !held) { handle.chooseDisk(it) }
            } else if (form.diskAlone.isNotEmpty()) {
                ListItem(headlineContent = { Text(sheetWords.disk) }, trailingContent = { Text(form.diskAlone) })
            }
            Footnote(form.narrowingFooter, Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        }
    }
}

@Composable
private fun Heading(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
         modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp))
}

/** One word of the condition, with the button that takes its row away where there is one. */
@Composable
private fun WordField(text: String, placeholder: String, enabled: Boolean, remove: (() -> Unit)?, type: (String) -> Unit) {
    val removeLabel = RecBridge.conditionsWords.removeRowLabel
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(value = text, onValueChange = type, placeholder = { Text(placeholder) }, singleLine = true,
                          enabled = enabled, keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                          modifier = Modifier.weight(1f))
        if (remove != null) {
            IconButton(onClick = remove, enabled = enabled) {
                Icon(Icons.Default.RemoveCircleOutline, contentDescription = removeLabel, tint = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun AddButton(label: String, enabled: Boolean, add: () -> Unit) {
    TextButton(onClick = add, enabled = enabled, modifier = Modifier.padding(horizontal = 8.dp)) {
        Icon(Icons.Default.Add, contentDescription = null, Modifier.size(18.dp))
        Text("  $label")
    }
}
