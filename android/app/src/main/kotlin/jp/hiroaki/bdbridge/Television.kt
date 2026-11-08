package jp.hiroaki.bdbridge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

// The television's sheets and the televisions a search found, as the iOS app has them (core/.../Television.swift):
// what each offers, holds back and says, and what each press does, are the model's.

/**
 * What the television's sheet is put up for: the address it opens on, whether it goes straight on to テレビに接続 -- a
 * television a search found, tapped -- and whether it registers with the one added again. `id` tells one request from
 * the next, so that the same address asked for twice opens the sheet afresh.
 */
data class TVSheetRequest(val host: String, val connectAtOnce: Boolean, val again: Boolean, val id: Long = nextRequest++)

private var nextRequest = 0L

/**
 * Adding a television, or registering with it again: its address, and then the PIN it shows on its screen. Put away
 * at any time: the step under way ends with the sheet, and nothing more is asked of the television.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TVRegisterSheetView(request: TVSheetRequest, close: () -> Unit) {
    val handle = rememberOpened(request.id) {
        if (request.again && request.host.isEmpty()) RecBridge.openTVRegisterAgain()
        else RecBridge.openTVRegister(request.host, request.connectAtOnce, request.again)
    }
    val sheet = handle?.let { it.shown.collectAsState().value }
    var host by remember(request.id) { mutableStateOf<String?>(null) }
    if (host == null && sheet != null) host = sheet.typedHost
    LaunchedEffect(handle) { handle?.appeared() }
    HeldSheet(held = false, done = sheet?.done ?: false, close = close) {
        Title(sheet?.title ?: if (request.again) "テレビを登録" else "テレビを追加")
        Column(Modifier.padding(horizontal = 24.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(value = host ?: request.host, onValueChange = {
                host = it
                handle?.typeHost(it)
            }, label = { Text("IP アドレス") }, placeholder = { Text("192.168.1.20") }, singleLine = true,
                enabled = sheet != null && !sheet.addressHeld,
                supportingText = { Text("テレビと同じ Wi-Fi につないだこの端末から登録します。") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                modifier = Modifier.fillMaxWidth())
            if (sheet?.askingForPIN == true && handle != null) {
                val pin by handle.pinField.text.collectAsState()
                OutlinedTextField(value = pin, onValueChange = { handle.pinField.type(it) }, label = { Text("4 桁の番号") },
                                  singleLine = true, supportingText = { Text(sheet.pinNote) },
                                  keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                                  modifier = Modifier.fillMaxWidth())
            }
            if (sheet != null && sheet.turnedAway.isNotEmpty()) {
                // In place of the address not answering: the sheet goes on by itself once it is allowed.
                Text(sheet.turnedAway, style = MaterialTheme.typography.bodyMedium)
            } else if (sheet != null && sheet.message.isNotEmpty()) {
                Text(sheet.message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { handle?.press() }, enabled = sheet != null && !sheet.pressHeld) {
                    Text(sheet?.pressLabel ?: "テレビに接続")
                }
                if (sheet?.working == true) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            }
        }
    }
}

/** Registering with the helper on the television, by the six-digit code its screen shows for five minutes. */
@Composable
fun HelperRegisterSheetView(key: Long, close: () -> Unit) {
    val handle = rememberOpened(key) { RecBridge.openHelperRegister() }
    val sheet = handle?.let { it.shown.collectAsState().value }
    var code by remember(key) { mutableStateOf("") }
    val uri = LocalUriHandler.current
    HeldSheet(held = false, done = sheet?.done ?: false, close = close) {
        Title("テレビの番組表に登録")
        Column(Modifier.padding(horizontal = 24.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(value = code, onValueChange = {
                code = it
                handle?.typeCode(it)
            }, label = { Text("6 桁の番号") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                modifier = Modifier.fillMaxWidth())
            Footnote("テレビで「RecBridge ヘルパー」を開き、「登録の番号を出す」で表示された 6 桁の番号を入力してください。"
                     + "番号は 5 分で消えます。")
            Footnote("ヘルパーをテレビに入れる手順は、GitHub の説明書にあります。")
            TextButton(onClick = { uri.openUri("https://github.com/hiroaki0923/bdzbridge/blob/main/helper/README.md") }) {
                Text("github.com/hiroaki0923/bdzbridge/helper")
            }
            if (sheet != null && sheet.message.isNotEmpty()) {
                Text(sheet.message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { handle?.press() }, enabled = sheet != null && !sheet.pressHeld) { Text("登録する") }
                if (sheet?.working == true) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            }
        }
    }
}

/**
 * The televisions a search found, under the recorders, in the tutorial and the settings alike. A row registers its
 * television while none is added -- the tap puts a number on the television's panel, and nothing but the tap does --
 * and with one added the rows are only listed, the one added in use, and the foot says why.
 */
@Composable
fun FoundTelevisionsCard(televisions: List<FoundTelevision>, enabled: Boolean, register: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Card(Modifier.fillMaxWidth()) {
            Text("見つかったテレビ", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
                 modifier = Modifier.padding(start = 16.dp, top = 12.dp))
            televisions.forEachIndexed { index, found ->
                if (index > 0) HorizontalDivider()
                ListItem(
                    leadingContent = { Icon(Icons.Outlined.Tv, contentDescription = null) },
                    headlineContent = { Text(found.name) },
                    supportingContent = { Text(found.host) },
                    trailingContent = {
                        if (found.inUse) Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Check, contentDescription = null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                            Text("使用中", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelLarge)
                        } else if (found.registers) {
                            Text("登録する", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelLarge)
                        }
                    },
                    modifier = if (found.registers) Modifier.clickable(enabled = enabled) { register(found.host) } else Modifier,
                )
            }
        }
        if (televisions.any { it.registers }) {
            Footnote("タップすると登録を始めます。テレビの画面に 4 桁の番号が出るので、その番号を入力してください。")
        } else {
            Footnote("使えるテレビは 1 台です。別のテレビを使うときは、設定の「テレビ」でいまのテレビを外してから、"
                     + "もう一度探してください。")
        }
    }
}

/**
 * What the television says it speaks, for the reader to copy and send on when the app does not work with it. Nothing
 * on the television changes.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CapabilitiesPage(close: () -> Unit) {
    BackHandler(onBack = close)
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    var reading by remember { mutableStateOf(false) }
    var report by remember { mutableStateOf<String?>(null) }
    Scaffold(topBar = {
        TopAppBar(title = { Text("テレビの対応状況") },
                  navigationIcon = { IconButton(onClick = close) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
               verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = {
                reading = true
                scope.launch {
                    report = RecBridge.tvCapabilities()
                    reading = false
                }
            }, enabled = !reading) { Text("調べる") }
            Footnote("テレビが対応している機能と、予約や録画の一覧を読めるかを調べます。読むだけで、"
                     + "テレビの予約や設定は変わりません。結果に番組名や局名は含まれません。"
                     + "うまく動かないときは、結果をコピーして、お問い合わせの際にお送りください。"
                     + "テレビに予約と録画が 1 件ずつあると、より詳しく分かります。")
            if (reading) {
                CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally))
            } else report?.let { said ->
                OutlinedButton(onClick = { clipboard.setText(AnnotatedString(said)) }) {
                    Icon(Icons.Outlined.ContentCopy, contentDescription = null, Modifier.size(18.dp))
                    Text("  コピー")
                }
                SelectionContainer {
                    Text(said, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace))
                }
            }
        }
    }
}
