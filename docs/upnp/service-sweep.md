# レコーダーが実際に何を答えるか（BDZ-FBT4100, 2026-09-15 実測）

`description.xml` が指しているものを一通り叩いた記録です。SCPD（`*.xml`）はアクションの一覧しか書いていない
ので、返ってくる中身をここに残します。レコーダーを変更する操作（電源・チャンネル・リモコン・作成/更新/削除・
機器登録）は叩いていません。個人環境の値（MAC・UDN・IP）は伏せてあります。

## device 要素に書いてあること

`docs/upnp/description.xml` にすべて入っています（見落としていましたが最初からありました）。

| 要素 | 値 | 意味 |
|---|---|---|
| `X_WakeupOnLAN` | `1` | **Wake-on-LAN 対応をレコーダー自身が申告している。** 取説には載っていない |
| `EPG_CAP` | `01` | EPG を持っている |
| `productName` / `modelDescription` | `BDZ-FBT4100` / `BDZ-202105` | 型番と世代 |
| `standardCDS` | `5.0` | ContentDirectory の世代 |
| `videoRoot` / `videoLiveTunerContainer` | `VideoRoot` / `AllVideoTuners` | Browse の入口 |
| `recordingPathDisability` | `R2:DRONLY_NOPORTABLE` | DR のみ・おでかけ転送不可の経路がある |
| `NEncThumbnail` | `1` | サムネイルは暗号化なし |
| `X_BdreTitleMove` | `7` | BD-RE へのムーブの種別 |
| `aggregationFlags` / `AvStreamSeekErrata` | `01` / `01` | DLNA の細目 |
| `X_SPTVCAP` / `X_JLABSCAP` | `MOVE-1.00` など | ムーブとアップロードの対応表 |

アイコン 4 つ（`icon-0.png` 48px, `icon-1.png` 120px, `icon-2.jpg`, `icon-3.jpg`）はすべて実物が返ります。
2〜6 KB。番組表の局ロゴと違って、こちらは機器そのもののアイコンです。

## サービスは 5 つ、うち 2 つは同じもの

| サービス | 制御 URL | アクション数 |
|---|---|---|
| ContentDirectory:1 | `/DMSContentDirectory` | 9 |
| ConnectionManager:1 | `/CMS` | 3 |
| X_ScheduledRecording:2 | `/XSRS` | 8 |
| X_ScheduledRecordingExt:1 | `/XSRSExt` | 8 |
| X_PvrControl:1 | `/X_PvrControl` | 25 |

**`/XSRSExt` は `/XSRS` の複製です。** SCPD が 1 バイト単位で同一で、同じ問い合わせに同じ答えを返します
（`TotalMatches` も一致）。クライアントの世代差を吸収するための別名でしょう。どちらを使っても構いません。

## X_PvrControl の読み取り専用アクション

| アクション | 返るもの |
|---|---|
| `X_GetPrivateIp` | **`macAddress` と `wirelessMacAddress`**、`ipAddress`、`subNetMask`、`defaultGateWay`、`primaryDns`、`secondaryDns`、`useDhcp`、`autoDns`、`ipUp` |
| `X_GetPlayStatus` | `powerstatus`（`PowerInternalOn` など）と `playstatus`（`Stopped` など） |
| `X_GetFirmwareVersion` | ファームウェア版 |
| `X_GetMediaInfo(recordDestinationID)` | `mount`、`remain` / `total`（**MB**）、`recordableRemain`（別単位。録画可能時間と思われる）、`registeredTime` |
| `X_GetTitleInfo(TitleID)` | `chapterNum` / `chapterTime`、`resumePoint`、`userPlaybackTime`（秒）、`recordStartDate`、`startPTS`、**`dlnaFlag`**、**`remoteViewFlag`**、`titleHevcFlag`、ダイジェスト再生用の `longest/normal/shortestDigestSceneList` |
| `X_GetTitleInfoExt(TitleID, Filter, Format)` | 1 件ぶんの `X_GetTitleList` 相当。`markingID`、`targetQualityMode` も付く |
| `X_GetRecordScheduleInfoExt(RecordScheduleID, ...)` | 1 件ぶんの `X_GetRecordScheduleList` 相当。**予約 1 件の生存確認に使える** |
| `X_GetLiveChList(BroadcastType, SkipChannel)` | 放送中のチャンネル一覧 |
| `X_GetWatchingChInfo` | 視聴中のチャンネル。何も見ていなければ空で `NumberReturned=0` |
| `X_ChkWlanOdekakeUsability(recordDestinationID)` | `WlanOdekakeUsable`（実機は `true`） |
| `X_GetPrefRecSettingList(..., Format)` | **おまかせ・まる録の条件一覧。`Format` は空でなければ 803。実機では 0 件** |
| `X_GetSetupInfo(SetupName)` | アプリ向け設定の読み出し。**`SetupName` に `*` を渡すと全項目**。下記参照 |
| `X_GetServiceStatus(Elements, ServiceName)` | `Elements` に `*`、`ServiceName` に `DLNA` か `MOVE`。下記参照 |

`X_GetPrefRecSettingList` が 0 件なのに `reservationCreatorID` が `1100`（レコーダー自身）の予約は存在します。
つまりこの一覧に載る「おまかせ・まる録の条件」とは別の仕組み（新番組おまかせ録画などの単発設定）が予約を
作っています。逆に、こちらが作っていない予約に `2200`（アプリが作成）が付いている例も観測しました。
`2200` を「自分が入れた予約」と読むのは危険です。

## ContentDirectory の木

```
0 ─ VideoRoot「ビデオ」
     ├ AllVideoGenres「ジャンル」
     ├ AllVideoDates「日付」
     ├ AllVideoFolders「フォルダ」
     ├ AllVideos「すべて」
     └ AllVideoTakes「おでかけ」
AllVideoTuners ─ VideoTuner00「地上デジタル」/ VideoTuner01「BSデジタル」/ VideoTuner02「１１０度ＣＳ」
```

`AllVideoTuners` は `VideoRoot` の子ではなく、`description.xml` の `videoLiveTunerContainer` から辿ります。
**BS4K のチューナーは出てきません。** ライブ配信できるのは 3 波までです。

### レコーダー側のグルーピング（2026-09-16 実測）

| コンテナ | 中身 | 使えるか |
|---|---|---|
| `AllVideoGenres` | ARIB 第 1 階層のジャンル 8 つ（`VideoGenre00`〜） | ジャンル別の一覧・件数はレコーダーに聞ける |
| `AllVideoDates` | 年ごと（`VideoYear2026` など） | 同上 |
| `AllVideoTakes` | ハイビジョン画質 / モバイル画質（おでかけ転送用） | 転送済みかの判定 |
| `AllVideoFolders` | **本体で手動で作ったグループ**。作っていなければ「グループなし」1 つに全件 | 番組単位のまとめは**出てこない** |

**番組単位のまとめはレコーダーからは取れません。** 本体画面の「まとめ」に相当するものは DLNA にも XSRS にも無く、
タイトルにグループを指す項目もありません（`xsrs-api.md` の全列挙）。名前ベースのグルーピングが必要なのはこのためです。

`AllVideoFolders` 配下の item は `MK_<n>`、ジャンル配下は `GR<nn>_<n>`、`AllVideos` 配下は `V_<n>` で、数値部分は
同じ録画を指します。フォルダとジャンルの item は DIDL-Lite の参照（`refID="V_<n>"`）で、実体は `AllVideos` の 1 件
だけです。`X_ConvertItemId` はこの対応のためのものかと考えていましたが、公式クライアントは呼んでいません。

**サムネイルは全件同一です。** `IMAGE_VTN_TN_<n>.jpg` の URL は録画ごとに違いますが、6 件取って比べたところ
サイズもハッシュも完全に一致しました（13035 バイト）。レコーダーが用意しているのは placeholder で、
録画の内容は写っていません。一覧にサムネイルを出さない判断はこの確認に基づきます。

その他: `GetSortCapabilities` は `dc:title,dc:date,upnp:genre,av:capturedDateTime`、`GetSearchCapabilities` は
**空**（`Search` は使えない）。`X_HDLnkGetRecordDestinations` は `HDD` 1 つ。`X_GetDLNAUploadProfiles` は
アップロード可能な 6 プロファイルを返します。`GetSystemUpdateID` は変更のたびに増える番号です。

## ConnectionManager

`connectionmanager-answers.txt` に別途。要点は、送信 33 プロファイル・受信 0、録画は DTCP-IP 経由でしか
出てこないこと、`PrepareForConnection` が無いので接続管理は実質存在しないこと。

## 引数の語彙は `*` で引き出せる

`X_GetSetupInfo` と `X_GetServiceStatus` は引数に決まった語彙を要求しますが、SCPD には手掛かりがありません。
`X_PvrControl.xml` には `allowedValueList` が**一つもなく**、`SetupName` の型も汎用の `A_ARG_TYPE_ObjectID` です。
取説の設定項目から作った候補 203 個（`StandbyMode` `QuickStart` `HomeServer` など、CamelCase と lowerCamel の
両方）は全滅で、返るのは一律 `803` でした。

答えは**ワイルドカード**でした。`SetupName` に `*` を渡すと有効な項目が全部返り、それが語彙そのものです。

| `SetupName` | 実機の値 | 中身 |
|---|---|---|
| `zipCode` | （伏せる） | **郵便番号。** 放送地域の判定用と思われる |
| `mobTarget` | `WIRELESS_DEV` | おでかけ転送の宛先種別 |
| `autoAvcCreate` | `1` | AVC 変換の自動作成 |
| `autoAvcCreateForAdvanced` | `1` | 同じものの上位設定 |
| `postMetaRecorderID` | （伏せる） | 機器を識別する不透明な ID |
| `ssid` | （空。有線なので） | 無線 LAN の SSID |
| `remoteAccessPermission` | `1` | 外からどこでも視聴の許可状態 |

この 7 つだけです。個別名でも同じ値が返り、他の名前はすべて 803。**スタンバイモード（高速起動）は含まれません**
ので、待機の挙動をこの API から読むことはできません。

`X_GetServiceStatus` も同じ発想で開きます。`Elements` が `*`、`ServiceName` が識別子で、`ServiceName` 自体に
`*` は使えません（803）。候補 60 個のうち通ったのは 2 つだけでした。

```xml
<object type="SERVICE" id="DLNA"><isCapable>1</isCapable><isAvailable>1</isAvailable></object>
<object type="SERVICE" id="MOVE"><isCapable>1</isCapable><isAvailable>1</isAvailable></object>
```

`isCapable` が「機器として対応しているか」、`isAvailable` が「今使えるか」でしょう。

### 認証なしで郵便番号が読めることについて

`X_GetSetupInfo` に認証はありません。同じ LAN にいる誰でも郵便番号と、無線接続なら SSID と、機器の ID を
読み出せます。移植するアプリは**これらを読む必要がないので読まないこと**。ログにも残さない。

## リストは絞り込みと並べ替えができる（未使用の機能）

`X_GetTitleList` と `X_GetRecordScheduleList` の `SearchCriteria` と `SortCriteria` は**生きています**。
この 2 つは今まで常に空で呼んでいましたが、レコーダー側で絞り込めます。1300 件を全ページ取得している
処理は、用途によっては 1 リクエストで済みます。

| | `X_GetTitleList`（録画） | `X_GetRecordScheduleList`（予約） |
|---|---|---|
| 検索できる項目 | `reservationCreatorID`、`recordDestinationID` | `reservationCreatorID` のみ |
| 他の項目 | `titleProtectFlag` `titleNewFlag` `recordingFlag` `genreID` `title contains …` は **861** | `conflictID` `recordingFlag` `recordDestinationID` は **860** |
| 並べ替え | `+scheduledStartDateTime` / `-scheduledStartDateTime` | 同じ |
| 他の並べ替え | `+title` `-title` `+recordSize` `+dc:title` は **809** | 同じ |
| 検索と並べ替えの併用 | できる | できる |
| `Filter` | **無視される。** `*`／`title`／`@id`／空でも返るバイト数が同一 | 同じ |

構文は UPnP 流の `フィールド = "値"` です。`SearchCriteria` に `*` は **860/861**、`SortCriteria` に `*` は
**809**。

**予約リストの罠。** `reservationCreatorID = "2200"` は実機に 19 件あるのに **0 件を返します**。`"1100"` は
20 件を正しく返します。つまり「アプリが入れた予約だけ」をレコーダー側で絞ることはできません。これで
絞った画面は空になり、予約が消えたように見えます。絞り込みは `1100`（レコーダー自身の予約）だけ信用できます。

**録画と予約で creator の値space が違います。** 録画 1323 件は `1100` が 282 件、`2000` が 1041 件で合計が
一致します。予約 39 件は `1100` が 20 件、`2200` が 19 件。つまり録画側は `2000`、予約側は `2200` です。

## 引数の棚卸し

### 語彙が確定しているもの

- `X_GetSetupInfo(SetupName)` — 7 項目。`*` で列挙できるので網羅的。
- `X_HDLnkGetRecordDestinationInfo` / `X_GetMediaInfo` / `X_ChkWlanOdekakeUsability` の `recordDestinationID`
  — `X_HDLnkGetRecordDestinations` が列挙してくれる（実機は `HDD` のみ）。網羅的。
- `Browse` の `BrowseFlag` — `BrowseMetadata` / `BrowseDirectChildren`。**CDS の SCPD が `allowedValueList` で
  宣言している**唯一の例。
- `GetCurrentConnectionInfo` の `Direction` / `Status` — ConnectionManager の SCPD が宣言済み。
- `SearchCriteria` / `SortCriteria` — 上の表のとおり、通る項目を総当たりで確定。

### 見つけたが網羅性は不明

- `X_GetServiceStatus` の `ServiceName` — `DLNA` と `MOVE` のみ。候補 84 個（`X_SPTVCAP` と `X_JLABSCAP` の
  トークンを含む）を試しての 2 件なので、未知の名前が残っている可能性はあります。
- `X_PlayControlTitle` の `Operation` — `play` / `pause` / `stop`（小文字）は実証済み。早送りや次章送りに
  相当する値があるかは不明。
- `X_PowerControl` の `Operation` — `on` は実証済み（`PowerOn` `On` は不可）。切る側の値は未検証。
- 観測から作った表（`scheduledConditionID`、`markingID`、`mediaRemainAlertID`、`powerstatus`、`playstatus`）—
  いずれも実機で見えた値だけ。網羅の保証はありません。`desiredQualityMode` は公式クライアントの表で埋まりました
  （`xsrs-api.md`）。

### まだ分からないもの

- **`X_ConvertItemId(Elements)`** — `<xsrs>` 配下に `object` / `item` / `titleID` を置く形はすべて **402**、
  XML でないものは **802**。形が分かりません。用途として想定していた「XSRS のタイトル ID と DLNA の `V_<n>` の
  対応」は、公式クライアントもビット演算（ID の下 8 桁の 16 進を十進に）で求めていて、このアクションは呼んで
  いません。本ソフトの求め方は公式と同じで、置き換える理由はなくなりました。
- `X_GetTitleInfoExt` / `X_GetRecordScheduleInfoExt` / `X_GetPrefRecSettingList` の `Format` — 空なら通り、
  `*` `1` `2` `xsrs` は **803**。語彙不明。
- `X_GetLiveChList` の `SkipChannel` — `0` `1` `*` 空 `true` `false` すべて 0 件でしたが、**レコーダーが待機中で
  ライブが無い状態での測定**なので結論になりません。電源が入っているときに再測定が必要。
- `X_InputRemoteKey` の `RemoteKey` — **総当たりしていません。** ボタンを押す操作なので読み取り専用の枠を
  出ます。キャプチャか、公式アプリの挙動からしか埋まりません（PC 版は呼んでいないので、スマホ版だけが手がかり）。
- `X_GetRecordScheduleFileSize`、`X_HDLnkGetRecordContainerID`、`X_ConvertItemId` 以外の `Elements` 引数、
  および書き込み系（`CreateObject`、`X_CreateNextRecordSchedule`、`X_RegisterRemoteDevice`、
  `X_CreatePrefRecSetting` 系）— 未検証。
- `Browse` の `ObjectID` — 上位 3 階層は歩きました（`0` → `VideoRoot` → 5 つ、`AllVideoTuners` → 3 波）。
  その下は未踏。

### エラーコードの意味（実測）

実機で出させたものだけを並べます。UPnP の標準コード（401/402/501/701）以外は Sony 独自です。

| コード | 出るとき | 確かめ方 |
|---|---|---|
| `402` | `Elements` の XML の形が違う。時刻のオフセットが `+0900` のような形式違反も含む | 作成要素の要素順を崩す |
| `701` | `Browse` の `ObjectID` がそんなオブジェクトを指していない | `ObjectID` に `*` |
| `802` | `Elements` が XML ではない、`ServiceName` が空 | `X_ConvertItemId` に生文字列 |
| `803` | 引数の値がその引数の語彙に無い（`SetupName`、`Format`、`ServiceName`、`recordDestinationID`）。実在しないチャンネルや放送種別の組み合わせもここ | `SetupName` に `QuickStart` |
| `804` | その予約 ID が無い。**レコーダーがおまかせ予約を振り直した後に古い ID を送ると普通に起きる** | 削除済みの ID を削除 |
| `809` | `SortCriteria` がその項目を並べ替えできない（`scheduledStartDateTime` 以外すべて） | `SortCriteria` に `+title` |
| `820` | そのタイトル ID が無い（`X_GetTitleInfo` / `X_GetTitleDetail` 系） | 存在しない録画 ID |
| `831` | **受信できないチャンネルの番組を `desiredMatchingID` 付きで予約しようとした。** 未契約の CS／BS で再現。録画モードや放送種別ではない | 未契約局＋eventID で作成 |
| `860` | `SearchCriteria` がその項目で検索できない（予約リスト） | `conflictID = "0"` |
| `861` | 同じもの（録画リスト） | `titleProtectFlag = "1"` |
| `874` | `X_GetTitleInfoExt` に `TitleID=0`。同じ入力で `X_GetTitleInfo` は 820 なので、Ext 系は別系統のコードを使っている | `TitleID` に `0` |
| `880` | ネットワークスタンバイ中で実行できない（再生など） | 待機中に `X_PlayControlTitle` |
| `884` | 未解明。BS の 60 秒の番組を `,,0x65,<event>` という matching id で予約したときに 1 度だけ観測。同じ形で別の番組は通るので、番組の長さか一時的な状態のどちらか | 再現せず |

`831` と `804` はアプリが利用者に説明しなければならない 2 つです。前者は「このチャンネルは受信できない」、
後者は「この予約はもうない」であって、どちらも操作の失敗ではありません。

**Sony 独自の 2 サービスは `allowedValueList` を一つも宣言していません**（`XSRS.xml` も `X_PvrControl.xml` も 0 件）。
規格上の引数一覧はここまでで、あとは `*` を試すか、総当たりか、キャプチャです。

## ワイルドカードを全引数に当てた結果

読み取り専用アクションの文字列引数すべてに `*` `%` `?` `all` `ALL` `any` `ANY` `*.*` `**` `.*` `-1` `0` を
入れて回しました。分かったことは 4 つです。

### 1. `*` が効くのは `X_GetSetupInfo` だけ

他の 11 種のワイルドカード候補はすべて 803 です。`X_GetServiceStatus` の `ServiceName` は `*` でも 803。
つまりこれは「ワイルドカードという作法」ではなく、この 1 アクションの実装にそう書いてあるだけです。

### 2. まったく見ていない引数がある

| アクション | 無視される引数 | 実際の挙動 |
|---|---|---|
| `X_GetServiceStatus` | `Elements` | 空でなければ何でも通り、答えは同じ |
| `X_ChkWlanOdekakeUsability` | `recordDestinationID` | 何を渡しても `WlanOdekakeUsable` |
| `X_HDLnkGetRecordDestinationInfo` | `RecordDestinationID` | 何を渡しても HDD の情報 |
| `X_HDLnkGetRecordContainerID` | `Elements` | 何を渡しても `0` |
| `X_GetTitleList` / `X_GetRecordScheduleList` | `Filter` | 返るバイト数が常に同一 |

`X_HDLnkGetRecordDestinationInfo` は属性で `totalCapacity` `availableCapacity` `dtcpSupport="1"`
`allowedTypes="HDD"` `recordable="1"` を返します。空き容量はこれが一次情報です。

### 3. `SearchCriteria` の値は整数として読まれ、読めなければ「全件」になる

`reservationCreatorID = "…"` に何を入れたか（録画 1323 件に対して）:

| 値 | 一致 |
|---|---|
| `1100` | 282 |
| `2000` | 1041 |
| `-1` / `9999` | 0 |
| `*` / `%` / `all` / `0` / 空 | **1323（全件）** |

**綴りを間違えるとエラーにならず全件返ります。** 絞り込んだつもりで全件取得している、という失敗をしても
気づけません。フィールド名の方を間違えた場合は 860/861 になるので、そちらは安全です。

### 4. `X_GetLiveChList` は引数を見ている（前回の測定は当方の解析ミス）

返るのは `<item>` の列ではなく `channelNum` と、サービス ID を `_` で連結した `channelList` です。
`<item>` を数えていたので 0 件に見えていました。待機中でも答えます。

| `BroadcastType` | `channelNum` |
|---|---|
| `2`（地上デジタル） | 27 |
| `3`（BS） | 60 |
| `4`（110度CS） | 57 |
| `23`（BS4K） | 9 |
| `*` や `99` など不明値 | 27（地上デジタルに落ちる） |

`SkipChannel` も効きます。地上デジタルで `0` なら 27、**`1` なら 31**。31 はロゴファイルのレコード数と
一致するので、`1` は「スキップ設定のチャンネルも含める」でしょう。

`X_ConvertItemId` はワイルドカードでも動きませんでした。XML でない値は 802、`<xsrs>` 配下に何を置いても
402。ここだけは総当たりで埋まりません。
