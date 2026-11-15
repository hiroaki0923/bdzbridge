package jp.hiroaki.bdbridge

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

// The tutorial's three sentences that are Android's own. The model's `Tutorial` words the rest (the steps, the
// footers);
// these name the device or the system's question, which differ here from the iOS app's: this device where iOS says
// iPhone, and no detail under step 3, which on iOS describes the system's local network question, one this app does not
// ask at the SDK it targets.
private const val INTRODUCTION = "ソニーのブルーレイディスクレコーダー（BDZ シリーズ）用のアプリです。" +
    "レコーダーの番組表をこの端末で見て、録画予約や録画した番組の整理ができます。" +
    "USB ハードディスクに録画できるソニーのテレビにも、録画予約を送れます。" +
    "まず、お使いのレコーダーとテレビを追加しましょう。"
private const val STEP_2_TITLE = "この端末をレコーダーやテレビと同じ Wi-Fi につなぐ"

/**
 * Where a recorder is chosen, as the iOS app's tutorial chooses one: what the app is and the steps to take, then the
 * search, an address, or the demo; and where a television the search found is registered, the search going on behind
 * its sheet. A screen of its own over the others, closed with × -- or put off with あとで設定 while nothing is set up --
 * and by itself once a recorder chosen here answers. `close` ends it, here and in the model.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(shown: Devices, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val address by RecBridge.devicesHostField.text.collectAsState()
    var tvSheet by remember { mutableStateOf<TVSheetRequest?>(null) }
    val tutorial = shown.tutorial
    LaunchedEffect(shown.done) { if (shown.done) close() }
    tvSheet?.let { request -> TVRegisterSheetView(request) { tvSheet = null } }
    BackHandler(onBack = close)
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("レコーダーを探す") },
            navigationIcon = {
                if (!shown.welcomes) IconButton(onClick = close) {
                    Icon(Icons.Default.Close, contentDescription = shown.closeLabel)
                }
            },
            actions = { if (shown.welcomes) TextButton(onClick = close) { Text(shown.closeLabel) } },
        )
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp),
                   verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("RecBridge", style = MaterialTheme.typography.headlineMedium)
                    Text(INTRODUCTION, style = MaterialTheme.typography.bodyMedium,
                         color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            item {
                Card(Modifier.fillMaxWidth()) {
                    Text(tutorial.heading, style = MaterialTheme.typography.titleSmall,
                         color = MaterialTheme.colorScheme.primary,
                         modifier = Modifier.padding(start = 16.dp, top = 12.dp))
                    Step(1, tutorial.step1Title, tutorial.step1Detail)
                    Step(2, STEP_2_TITLE, tutorial.step2Detail)
                    Step(3, tutorial.step3Title, "")
                    Step(4, tutorial.step4Title, tutorial.step4Detail)
                }
            }
            item {
                Button(onClick = { scope.launch { RecBridge.act { it.devices.search() } } },
                       enabled = !shown.searchHeld, modifier = Modifier.fillMaxWidth()) {
                    if (shown.searching) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Text("  レコーダーとテレビを探す")
                    } else {
                        Text("レコーダーとテレビを探す")
                    }
                }
            }
            // Right under the button, where the reader is looking.
            if (shown.permissionNotice.isNotEmpty()) item {
                Text(shown.permissionNotice, color = MaterialTheme.colorScheme.error,
                     style = MaterialTheme.typography.bodyMedium)
            }
            if (shown.toSearch > 0) item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    LinearProgressIndicator(progress = { shown.searched.toFloat() / shown.toSearch }, Modifier.fillMaxWidth())
                    Footnote("検索中 ${shown.searched} / ${shown.toSearch}")
                }
            }
            if (shown.outcome.isNotEmpty()) item {
                SearchOutcome(shown.outcome, shown.outcomeFailed, shown.outcomeNote, shown.causes)
            }
            if (shown.busy.isNotEmpty()) item {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Text(shown.busy, style = MaterialTheme.typography.bodyMedium)
                }
            }
            if (shown.problem.isNotEmpty()) item {
                Text(shown.problem, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
            }
            if (shown.recorders.isNotEmpty()) item {
                FoundRecordersCard(shown.recorders, shown.canChoose) { host ->
                    scope.launch { RecBridge.act { it.devices.choose(host) } }
                }
            }
            if (shown.televisions.isNotEmpty()) item {
                FoundTelevisionsCard(shown.televisions, enabled = !shown.choosing) { host ->
                    tvSheet = TVSheetRequest(host, connectAtOnce = true, again = false)
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (shown.typing) {
                        OutlinedTextField(value = address, onValueChange = { RecBridge.devicesHostField.type(it) },
                                          singleLine = true, label = { Text("IP アドレス") },
                                          placeholder = { Text("192.168.1.10") },
                                          keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri,
                                                                            autoCorrectEnabled = false),
                                          isError = shown.addressWarning, modifier = Modifier.fillMaxWidth(),
                                          supportingText = if (shown.addressNote.isNotEmpty()) {
                                              { Text(shown.addressNote) }
                                          } else null)
                        Button(onClick = { RecBridge.afterTypingInDevices { it.connectTyped() } },
                               enabled = !shown.connectHeld) { Text("このアドレスに接続") }
                    } else {
                        OutlinedButton(onClick = { scope.launch { RecBridge.act { it.devices.showAddress() } } },
                                       modifier = Modifier.fillMaxWidth()) { Text("IP アドレスを直接入力") }
                    }
                    Footnote(tutorial.addressFooter)
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = {
                        scope.launch {
                            RecBridge.act { it.devices.enterDemo() }
                            close()
                        }
                    }, enabled = !shown.demoHeld) { Text("サンプルデータで試す") }
                    Footnote(tutorial.demoFooter)
                }
            }
        }
    }
}

/**
 * One step of the setup: its number in a tonal circle, what to do, and under it what to know, when there is something.
 */
@Composable
private fun Step(number: Int, title: String, detail: String) {
    ListItem(
        leadingContent = {
            Surface(shape = CircleShape, color = MaterialTheme.colorScheme.secondaryContainer,
                    contentColor = MaterialTheme.colorScheme.onSecondaryContainer, modifier = Modifier.size(28.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Text("$number", style = MaterialTheme.typography.labelLarge)
                }
            }
        },
        headlineContent = { Text(title) },
        supportingContent = if (detail.isNotEmpty()) ({ Text(detail) }) else null,
    )
}
