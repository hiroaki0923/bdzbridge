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
fun SettingsScreen(arrange: () -> Unit, readDisclaimer: () -> Unit, checkTV: () -> Unit) {
    val shown = RecBridge.settings.collectAsState().value
        ?: return Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { RecBridge.act { it.settings.appeared() } }
    var guideFailure by remember { mutableStateOf<String?>(null) }
    var tvSheet by remember { mutableStateOf<TVSheetRequest?>(null) }
    var helperSheet by remember { mutableStateOf<Long?>(null) }
    guideFailure?.let { said ->
        AlertDialog(onDismissRequest = { guideFailure = null },
                    confirmButton = { TextButton(onClick = { guideFailure = null }) { Text("OK") } },
                    title = { Text("番組表を取得できませんでした") }, text = { Text(said) })
    }
    tvSheet?.let { request -> TVRegisterSheetView(request) { tvSheet = null } }
    helperSheet?.let { key -> HelperRegisterSheetView(key) { helperSheet = null } }
    if (shown.television.asksToRemove) {
        val close = { scope.launch { RecBridge.act { it.settings.removalClosed() } } }
        AlertDialog(onDismissRequest = { close() },
                    title = { Text(shown.television.removalQuestion) }, text = { Text(shown.television.removalMessage) },
                    confirmButton = {
                        TextButton(onClick = { scope.launch { RecBridge.act { it.settings.confirmRemovingTV() } } }) {
                            Text("外す", color = MaterialTheme.colorScheme.error)
                        }
                    },
                    dismissButton = { TextButton(onClick = { close() }) { Text("キャンセル") } })
    }
    Scaffold(topBar = { TopAppBar(title = { Text("設定") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 24.dp)) {
            item { Heading("レコーダー") }
            items(shown.facts) { FactItem(it) }
            if (shown.standing.isNotEmpty()) item { FactItem(Fact("状態", shown.standing)) }
            item { RecorderFields(shown) }

            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item { QualityItem(shown) }
            item {
                Footnote("録画予約とおまかせ・まる録の条件を追加するときに、最初に選ばれている録画モードです。"
                         + "予約するときに変えても、ここは変わりません。", Modifier.padding(horizontal = 16.dp))
            }

            television(shown, check = checkTV, register = { tvSheet = it }, registerHelper = { helperSheet = it })

            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = { scope.launch { RecBridge.act { it.settings.search() } } }, enabled = !shown.searchHeld,
                           modifier = Modifier.fillMaxWidth()) { Text("レコーダーとテレビを探す") }
                    if (shown.toSearch > 0) {
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            LinearProgressIndicator(progress = { shown.searched.toFloat() / shown.toSearch }, Modifier.fillMaxWidth())
                            Footnote("検索中 ${shown.searched} / ${shown.toSearch}")
                        }
                    }
                    if (shown.outcome.isNotEmpty()) SearchOutcome(shown.outcome, shown.outcomeFailed, shown.outcomeNote, shown.causes)
                    // In the demo the search finds the invented recorder and television alone, and nothing real.
                    Footnote(if (shown.demo) "サンプルデータの表示中は、架空のレコーダーとテレビだけが見つかります。"
                                             + "実際の機器を探すときは、先にサンプルを終了してください。"
                             else "同じ Wi-Fi 上のレコーダーとテレビを探します。レコーダーを選ぶとそのレコーダーに切り替わり、"
                                  + "テレビを選ぶとテレビの登録を始めます。")
                    if (shown.recorders.isNotEmpty()) {
                        FoundRecordersCard(shown.recorders, shown.canChoose) { host ->
                            scope.launch { RecBridge.act { it.settings.choose(host) } }
                        }
                    }
                    if (shown.televisions.isNotEmpty()) {
                        FoundTelevisionsCard(shown.televisions, enabled = true) { host ->
                            tvSheet = TVSheetRequest(host, connectAtOnce = true, again = false)
                        }
                    }
                }
            }

            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item {
                ListItem(headlineContent = { Text("チャンネルの表示と並び順") },
                         trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                         modifier = Modifier.clickable(onClick = arrange))
            }
            item {
                Footnote("番組表に出す局と、その並び順を放送ごとに選べます。この端末の番組表だけが変わり、"
                         + "レコーダーの録画には影響しません。", Modifier.padding(horizontal = 16.dp))
            }

            item { Heading("保存されている番組表") }
            if (shown.guideSources.isNotEmpty()) item { GuideSourceItem(shown) }
            else if (shown.guideSourceAlone.isNotEmpty()) item { FactItem(Fact("番組表の取得元", shown.guideSourceAlone)) }
            items(shown.guide) { FactItem(it) }
            item {
                OutlinedButton(onClick = {
                    scope.launch {
                        val said = RecBridge.ask { it.settings.refreshGuide() }
                        if (said.isNotEmpty()) guideFailure = said
                    }
                }, enabled = !shown.refreshHeld, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text("番組表を更新")
                }
            }
            if (shown.guideSources.isNotEmpty()) item {
                Footnote("テレビの番組表は、番組名などが半角で表示されます。予約、局の設定、ロゴはどちらを選んでも変わりません。"
                         + (if (shown.helperProblem.isNotEmpty()) "\n" + shown.helperProblem else ""),
                         Modifier.padding(horizontal = 16.dp))
            } else if (shown.helperProblem.isNotEmpty()) item {
                Text(shown.helperProblem, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium,
                     modifier = Modifier.padding(horizontal = 16.dp))
            }

            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item { Demo(shown) }

            item { Heading("このアプリ") }
            // Before the version, because it is the one thing here worth reading: what this app writes to the recorder,
            // it writes for real.
            item {
                ListItem(headlineContent = { Text("ご利用上の注意") },
                         trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                         modifier = Modifier.clickable(onClick = readDisclaimer))
            }
            // Selectable, so that it can be copied into a report rather than read off a screen.
            item { SelectionContainer { FactItem(Fact("バージョン", shown.version)) } }

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
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(value = host, onValueChange = { RecBridge.hostField.type(it) }, label = { Text("IP アドレス") }, placeholder = { Text("192.168.1.10") }, singleLine = true,
                          isError = shown.addressWarning,
                          supportingText = if (shown.addressNote.isNotEmpty()) ({ Text(shown.addressNote) }) else null,
                          keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                          modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = mac, onValueChange = { RecBridge.macField.type(it) }, label = { Text("MAC アドレス") }, placeholder = { Text("接続時に自動で記録") }, singleLine = true,
                          keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None,
                                                            autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii),
                          modifier = Modifier.fillMaxWidth())
        if (shown.offersConnect) {
            FilledTonalButton(onClick = { RecBridge.afterTyping { it.connect() } }, enabled = !shown.connectHeld) {
                Text("このアドレスに接続")
            }
        } else if (shown.offersReconnect) {
            FilledTonalButton(onClick = { RecBridge.afterTyping { it.reconnect() } }, enabled = !shown.reconnectHeld) {
                Text("再接続")
            }
        }
        Footnote("MAC アドレスは、スリープ中のレコーダーを起動するために使います。接続時に自動で記録されるので、通常は入力不要です。")
    }
}

/**
 * The television's part: with one added, what it says of itself, 対応状況を調べる, what brings it back, the helper, and
 * テレビを外す, which asks first; with none, the way to add one by its address.
 */
private fun LazyListScope.television(shown: Settings, check: () -> Unit, register: (TVSheetRequest) -> Unit,
                                     registerHelper: (Long) -> Unit) {
    val part = shown.television
    item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
    item { Heading("テレビ") }
    if (!part.added) {
        item {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { register(TVSheetRequest("", connectAtOnce = false, again = false)) }) {
                    Text("アドレスを入力して追加")
                }
                Footnote(if (shown.demo) "サンプルデータでは、架空のテレビを追加して試せます。"
                                         + "サンプルを終了すると、架空のテレビも消えます。"
                         else "テレビは、「レコーダーとテレビを探す」で探せます。見つからないときは、テレビの IP アドレスを"
                              + "入力して追加できます。登録のときに、テレビの画面に表示される 4 桁の番号を入力します。")
            }
        }
        return
    }
    items(part.facts) { FactItem(it) }
    item {
        ListItem(headlineContent = { Text("対応状況を調べる") },
                 trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) },
                 modifier = Modifier.clickable(onClick = check))
    }
    if (part.offersTheHelper) item {
        FactItem(Fact("番組表（ヘルパー）", if (part.helperRegistered) "登録済み" else "未登録"))
    }
    item {
        val scope = rememberCoroutineScope()
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (part.offersRegistering) {
                FilledTonalButton(onClick = { register(TVSheetRequest("", connectAtOnce = false, again = true)) }) {
                    Text("登録する")
                }
            } else if (part.offersReconnect) {
                FilledTonalButton(onClick = { scope.launch { RecBridge.act { it.settings.reconnectTV() } } },
                                  enabled = !part.reconnectHeld) { Text("再接続") }
            }
            if (part.offersTheHelper) {
                if (part.helperRegistered) {
                    OutlinedButton(onClick = { scope.launch { RecBridge.act { it.settings.forgetHelper() } } },
                                   colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                        Text("ヘルパーの登録を解除")
                    }
                } else {
                    OutlinedButton(onClick = { registerHelper(System.nanoTime()) }) { Text("ヘルパーに登録") }
                }
            }
            OutlinedButton(onClick = { scope.launch { RecBridge.act { it.settings.removeTV() } } }, enabled = !part.removeHeld,
                           colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                Text("テレビを外す")
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
        ListItem(headlineContent = { Text("番組表の取得元") },
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
        ListItem(headlineContent = { Text("既定の録画モード") },
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
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (shown.demo) {
            OutlinedButton(onClick = { scope.launch { RecBridge.act { it.settings.leaveDemo() } } }, enabled = shown.canChoose,
                           colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                Text("サンプルデータを終了する")
            }
            Footnote("架空のレコーダーを表示しています。終了すると、サンプルの番組表と、追加した架空のテレビは削除され、"
                     + "元のレコーダーとテレビの設定に戻ります。レコーダーを選んで接続したときも、サンプルは終了します。")
        } else {
            OutlinedButton(onClick = { scope.launch { RecBridge.act { it.settings.enterDemo() } } }, enabled = shown.canChoose) {
                Text("サンプルデータで試す")
            }
            Footnote("レコーダーが無いときに、架空の番組表と録画一覧でアプリの動きを確かめられます。")
        }
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
