package jp.hiroaki.bdbridge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

// The settings, as the iOS settings screen has them, of what Android has yet (core/.../Settings.swift): what each
// field follows, each button offers and holds back, and each press does, are the model's.

/**
 * The settings: the recorder, the mode a new reservation starts at, the television, the search, the stations, the
 * guide kept on this device, the demo and the app. Sections in the iOS screen's order, a heading over each that has one
 * there. The television's sheet is this screen's, whether its part asked for it or a television the search found.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(arrange: () -> Unit, readDisclaimer: () -> Unit, setUp: () -> Unit, checkTV: () -> Unit) {
    val shown = RecBridge.settings.collectAsState().value
        ?: return Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    val scope = rememberCoroutineScope()
    val words = RecBridge.settingsWords
    LaunchedEffect(Unit) { RecBridge.act { it.settings.appeared() } }
    var guideFailure by remember { mutableStateOf<String?>(null) }
    var tvSheet by remember { mutableStateOf<TVSheetRequest?>(null) }
    var helperSheet by remember { mutableStateOf<Long?>(null) }
    guideFailure?.let { said ->
        AlertDialog(onDismissRequest = { guideFailure = null },
                    confirmButton = { TextButton(onClick = { guideFailure = null }) { Text("OK") } },
                    title = { Text(words.refreshFailedTitle) }, text = { Text(said) })
    }
    tvSheet?.let { request -> TVRegisterSheetView(request) { tvSheet = null } }
    helperSheet?.let { key -> HelperRegisterSheetView(key) { helperSheet = null } }
    if (shown.television.asksToRemove) {
        val close = { scope.launch { RecBridge.act { it.settings.removalClosed() } } }
        AlertDialog(onDismissRequest = { close() },
                    title = { Text(shown.television.removalQuestion) }, text = { Text(shown.television.removalMessage) },
                    confirmButton = {
                        TextButton(onClick = { scope.launch { RecBridge.act { it.settings.confirmRemovingTV() } } }) {
                            Text(shown.television.confirmRemovingLabel, color = MaterialTheme.colorScheme.error)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { close() }) { Text(shown.television.cancelRemovingLabel) }
                    })
    }
    Scaffold(topBar = { TopAppBar(title = { Text(words.title) }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 24.dp)) {
            item { Heading(words.recorderHeading) }
            items(shown.facts) { FactItem(it) }
            if (shown.standing.isNotEmpty()) item { FactItem(Fact(words.standingLabel, shown.standing)) }
            item { RecorderFields(shown) }

            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item { QualityItem(shown) }
            item { Footnote(words.defaultQualityFooter, Modifier.padding(horizontal = 16.dp)) }

            television(shown, check = checkTV, register = { tvSheet = it }, registerHelper = { helperSheet = it })

            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = { scope.launch { RecBridge.act { it.settings.search() } } }, enabled = !shown.searchHeld,
                           modifier = Modifier.fillMaxWidth()) { Text(words.searchLabel) }
                    if (shown.toSearch > 0) {
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            LinearProgressIndicator(progress = { shown.searched.toFloat() / shown.toSearch }, Modifier.fillMaxWidth())
                            Footnote(shown.searchingLine)
                        }
                    }
                    if (shown.outcome.isNotEmpty()) SearchOutcome(shown.outcome, shown.outcomeFailed, shown.outcomeNote, shown.causes)
                    Footnote(shown.searchFooter)
                    if (shown.recorders.isNotEmpty()) {
                        FoundRecordersCard(shown.recorders, shown.canChoose) { host ->
                            scope.launch { RecBridge.act { it.settings.choose(host) } }
                        }
                    }
                    if (shown.televisions.isNotEmpty()) {
                        FoundTelevisionsCard(shown.televisions, shown.televisionsFooter, enabled = true) { host ->
                            tvSheet = TVSheetRequest(host, connectAtOnce = true, again = false)
                        }
                    }
                }
            }

            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item {
                ListItem(headlineContent = { Text(words.channelsLabel) },
                         trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                         modifier = Modifier.clickable(onClick = arrange))
            }
            item { Footnote(words.channelsFooter, Modifier.padding(horizontal = 16.dp)) }

            item { Heading(words.guideHeading) }
            if (shown.guideSources.isNotEmpty()) item { GuideSourceItem(shown) }
            else if (shown.guideSourceAlone.isNotEmpty()) item {
                FactItem(Fact(words.guideSourceLabel, shown.guideSourceAlone))
            }
            items(shown.guide) { FactItem(it) }
            item {
                OutlinedButton(onClick = {
                    scope.launch {
                        val said = RecBridge.ask { it.settings.refreshGuide() }
                        if (said.isNotEmpty()) guideFailure = said
                    }
                }, enabled = !shown.refreshHeld, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text(words.refreshGuideLabel)
                }
            }
            if (shown.guideSources.isNotEmpty()) item {
                Footnote(shown.guideSourceFooter, Modifier.padding(horizontal = 16.dp))
            } else if (shown.helperProblem.isNotEmpty()) item {
                Text(shown.helperProblem, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium,
                     modifier = Modifier.padding(horizontal = 16.dp))
            }

            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item { Demo(shown) }

            item {
                ListItem(headlineContent = { Text(shown.tutorialRow) },
                         trailingContent = {
                             Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null)
                         },
                         modifier = Modifier.clickable(onClick = setUp))
            }

            item { Heading(words.appHeading) }
            // Before the version, because it is the one thing here worth reading: what this app writes to the recorder,
            // it writes for real.
            item {
                ListItem(headlineContent = { Text(words.disclaimerLabel) },
                         trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                         modifier = Modifier.clickable(onClick = readDisclaimer))
            }
            // Selectable, so that it can be copied into a report rather than read off a screen.
            item { SelectionContainer { FactItem(Fact(words.versionLabel, shown.version)) } }

            if (shown.busy.isNotEmpty()) item {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Text(shown.busy, style = MaterialTheme.typography.bodyMedium)
                }
            }
            // The phone's own, under the recorder's: its cache, which no device said anything of.
            for (problem in listOf(shown.problem, shown.phoneProblem).filter { it.isNotEmpty() }) item {
                Text(problem, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium,
                     modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            }
        }
    }
}

/**
 * The address and the MAC, as typed, and このアドレスに接続 or 再接続. Each field shows what is typed as it is typed, and
 * the model's value when the model has set the field itself -- the address saved, or the recorder found somewhere
 * else (`RecBridge.Field`).
 */
@Composable
private fun RecorderFields(shown: Settings) {
    val host by RecBridge.hostField.text.collectAsState()
    val mac by RecBridge.macField.text.collectAsState()
    val words = RecBridge.settingsWords
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(value = host, onValueChange = { RecBridge.hostField.type(it) }, label = { Text(words.hostLabel) }, placeholder = { Text(words.hostPlaceholder) }, singleLine = true,
                          isError = shown.addressWarning,
                          supportingText = if (shown.addressNote.isNotEmpty()) ({ Text(shown.addressNote) }) else null,
                          keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                          modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = mac, onValueChange = { RecBridge.macField.type(it) }, label = { Text(words.macLabel) }, placeholder = { Text(words.macPlaceholder) }, singleLine = true,
                          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None,
                                                            autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii),
                          modifier = Modifier.fillMaxWidth())
        if (shown.offersConnect) {
            FilledTonalButton(onClick = { RecBridge.afterTyping { it.connect() } }, enabled = !shown.connectHeld) {
                Text(words.connectLabel)
            }
        } else if (shown.offersReconnect) {
            FilledTonalButton(onClick = { RecBridge.afterTyping { it.reconnect() } }, enabled = !shown.reconnectHeld) {
                Text(words.reconnectLabel)
            }
        }
        Footnote(words.recorderFooter)
    }
}

/**
 * The television's part: with one added, what it says of itself, 対応状況を調べる, what brings it back, the helper, and
 * テレビを外す, which asks first; with none, the way to add one by its address. In the part's words, which come with
 * its read.
 */
private fun LazyListScope.television(shown: Settings, check: () -> Unit, register: (TVSheetRequest) -> Unit,
                                     registerHelper: (Long) -> Unit) {
    val part = shown.television
    item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
    item { Heading(part.heading) }
    if (!part.added) {
        item {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { register(TVSheetRequest("", connectAtOnce = false, again = false)) }) {
                    Text(part.addLabel)
                }
                Footnote(part.noTelevisionFooter)
            }
        }
        return
    }
    items(part.facts) { FactItem(it) }
    item {
        ListItem(headlineContent = { Text(part.capabilitiesLabel) },
                 trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                 modifier = Modifier.clickable(onClick = check))
    }
    if (part.offersTheHelper) item { FactItem(Fact(part.helperLabel, part.helperShown)) }
    item {
        val scope = rememberCoroutineScope()
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (part.offersRegistering) {
                FilledTonalButton(onClick = { register(TVSheetRequest("", connectAtOnce = false, again = true)) }) {
                    Text(part.registerLabel)
                }
            } else if (part.offersReconnect) {
                FilledTonalButton(onClick = { scope.launch { RecBridge.act { it.settings.reconnectTV() } } },
                                  enabled = !part.reconnectHeld) { Text(part.reconnectLabel) }
            }
            if (part.offersTheHelper) {
                if (part.helperRegistered) {
                    OutlinedButton(onClick = { scope.launch { RecBridge.act { it.settings.forgetHelper() } } },
                                   colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                        Text(part.forgetHelperLabel)
                    }
                } else {
                    OutlinedButton(onClick = { registerHelper(System.nanoTime()) }) { Text(part.registerHelperLabel) }
                }
            }
            OutlinedButton(onClick = { scope.launch { RecBridge.act { it.settings.removeTV() } } }, enabled = !part.removeHeld,
                           colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                Text(part.removeLabel)
            }
            // Why 外す left the television in place, above what went wrong with the television: both when both stand.
            if (part.footer.isNotEmpty()) {
                Text(part.footer, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

/** 番組表の取得元, where both a recorder and a registered helper could give the guide, chosen from a menu under it. */
@Composable
private fun GuideSourceItem(shown: Settings) {
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    Box {
        ListItem(headlineContent = { Text(RecBridge.settingsWords.guideSourceLabel) },
                 supportingContent = { Text(shown.guideSources.firstOrNull { it.code == shown.guideSource }?.label ?: "") },
                 trailingContent = { Icon(Icons.Default.ArrowDropDown, contentDescription = null) },
                 modifier = Modifier.clickable { open = true })
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for (source in shown.guideSources) {
                DropdownMenuItem(text = { Text(source.label) }, onClick = {
                    open = false
                    scope.launch { RecBridge.act { it.settings.chooseGuideSource(source.code) } }
                }, leadingIcon = {
                    if (source.code == shown.guideSource) Icon(Icons.Default.Check, contentDescription = null)
                    else Box(Modifier.size(24.dp))
                })
            }
        }
    }
}

/** 既定の録画モード, chosen from a menu under it. */
@Composable
private fun QualityItem(shown: Settings) {
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    Box {
        ListItem(headlineContent = { Text(RecBridge.settingsWords.defaultQualityLabel) },
                 supportingContent = { Text(shown.qualities.firstOrNull { it.code == shown.quality }?.label ?: shown.quality) },
                 trailingContent = { Icon(Icons.Default.ArrowDropDown, contentDescription = null) },
                 modifier = Modifier.clickable { open = true })
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for (quality in shown.qualities) {
                DropdownMenuItem(text = { Text(quality.label) }, onClick = {
                    open = false
                    scope.launch { RecBridge.act { it.settings.chooseQuality(quality.code) } }
                }, leadingIcon = {
                    if (quality.code == shown.quality) Icon(Icons.Default.Check, contentDescription = null)
                    else Box(Modifier.size(24.dp))
                })
            }
        }
    }
}

/** サンプルデータで試す, or サンプルデータを終了する while it is shown: not while a connect, a load or a job is under way. */
@Composable
private fun Demo(shown: Settings) {
    val scope = rememberCoroutineScope()
    val words = RecBridge.settingsWords
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (shown.demo) {
            OutlinedButton(onClick = { scope.launch { RecBridge.act { it.settings.leaveDemo() } } }, enabled = shown.canChoose,
                           colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                Text(words.leaveDemoLabel)
            }
        } else {
            OutlinedButton(onClick = { scope.launch { RecBridge.act { it.settings.enterDemo() } } }, enabled = shown.canChoose) {
                Text(words.enterDemoLabel)
            }
        }
        Footnote(shown.demoFooter)
    }
}

/** A section's heading, as Material's lists have one. */
@Composable
private fun Heading(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
         modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 24.dp, bottom = 4.dp))
}

/** A label with what is said of it under it, as Android's settings list a value. */
@Composable
private fun FactItem(fact: Fact) {
    ListItem(headlineContent = { Text(fact.label) }, supportingContent = { Text(fact.value) })
}

/** ご利用上の注意, over the screens, with the way back. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DisclaimerPage(close: () -> Unit) {
    BackHandler(onBack = close)
    val text by produceState<Disclaimer?>(null) { value = RecBridge.disclaimer() }
    val uri = LocalUriHandler.current
    Scaffold(topBar = {
        TopAppBar(title = { Text(text?.title ?: "") },
                  navigationIcon = { IconButton(onClick = close) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る") } })
    }) { padding ->
        val said = text ?: return@Scaffold
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
               verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Text(said.opening, style = MaterialTheme.typography.bodyLarge)
            for (section in said.sections) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(section.label, style = MaterialTheme.typography.titleMedium)
                    Text(section.value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            TextButton(onClick = { uri.openUri(said.url) }) { Text(said.link) }
        }
    }
}
