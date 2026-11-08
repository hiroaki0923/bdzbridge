package jp.hiroaki.bdbridge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Router
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/**
 * Where a recorder is chosen, as the iOS app's tutorial chooses one: the search, an address, or the demo. A screen of
 * its own over the others, closed with × -- or put off with あとで設定 while nothing is set up.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(shown: Devices, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    var typing by rememberSaveable { mutableStateOf(false) }
    var address by rememberSaveable { mutableStateOf("") }
    var typed by remember { mutableStateOf(Typed("", false, "", false)) }
    LaunchedEffect(address) { typed = RecBridge.typed(address) }
    BackHandler(onBack = close)
    Scaffold(topBar = {
        TopAppBar(
            title = { Text("レコーダーを探す") },
            navigationIcon = {
                if (!shown.welcomes) IconButton(onClick = close) { Icon(Icons.Default.Close, contentDescription = "閉じる") }
            },
            actions = { if (shown.welcomes) TextButton(onClick = close) { Text("あとで設定") } },
        )
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp),
                   verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Button(onClick = { scope.launch { RecBridge.act { it.devices.search() } } },
                       enabled = !shown.searching && shown.busy.isEmpty(), modifier = Modifier.fillMaxWidth()) {
                    if (shown.searching) {
                        CircularProgressIndicator(Modifier.size(16.dp).padding(end = 0.dp), strokeWidth = 2.dp)
                        Text("  レコーダーとテレビを探す")
                    } else {
                        Text("レコーダーとテレビを探す")
                    }
                }
            }
            if (shown.toSearch > 0) item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    LinearProgressIndicator(progress = { shown.searched.toFloat() / shown.toSearch }, Modifier.fillMaxWidth())
                    Footnote("検索中 ${shown.searched} / ${shown.toSearch}")
                }
            }
            if (shown.outcome.isNotEmpty()) item { Outcome(shown) }
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
                Card(Modifier.fillMaxWidth()) {
                    Text("見つかったレコーダー", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
                         modifier = Modifier.padding(start = 16.dp, top = 12.dp))
                    shown.recorders.forEachIndexed { index, found ->
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
                            modifier = Modifier.clickable(enabled = shown.canChoose) {
                                scope.launch { RecBridge.act { it.devices.choose(found.host) } }
                            },
                        )
                    }
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (typing) {
                        OutlinedTextField(value = address, onValueChange = { address = it }, singleLine = true,
                                          label = { Text("IP アドレス") }, placeholder = { Text("192.168.1.10") },
                                          keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                                          isError = typed.warning, modifier = Modifier.fillMaxWidth(),
                                          supportingText = if (typed.note.isNotEmpty()) ({ Text(typed.note) }) else null)
                        Button(onClick = {
                            address = typed.host
                            scope.launch { RecBridge.act { it.devices.choose(typed.host) } }
                        }, enabled = typed.usable && shown.canChoose) { Text("このアドレスに接続") }
                    } else {
                        OutlinedButton(onClick = { typing = true }, modifier = Modifier.fillMaxWidth()) { Text("IP アドレスを直接入力") }
                    }
                    Footnote("見つからない場合は、レコーダーの設定画面で確認できる IP アドレスを直接入力できます。")
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = {
                        scope.launch {
                            RecBridge.act { it.devices.enterDemo() }
                            close()
                        }
                    }, enabled = shown.canChoose) { Text("サンプルデータで試す") }
                    Footnote("レコーダーが無くても、架空の番組表と録画一覧でアプリの動きを確かめられます。"
                             + "実在の放送局・番組ではありません。")
                }
            }
        }
    }
}

/** What the search came to, with the likely causes under it when it found nothing. */
@Composable
private fun Outcome(shown: Devices) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(shown.outcome, style = MaterialTheme.typography.bodyMedium,
             color = if (shown.outcomeFailed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        if (shown.outcomeNote.isNotEmpty()) Footnote(shown.outcomeNote)
        if (shown.causes.isNotEmpty()) {
            Text("考えられる原因", style = MaterialTheme.typography.labelMedium)
            for (cause in shown.causes) Footnote("・$cause")
        }
    }
}
