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
| `X_GetSetupInfo(SetupName)` | 本体設定の読み出し。`SetupName` の語彙が不明で、`QuickStart` `NetworkStandby` `PowerSave` `HomeServer` `StandbyMode` `WakeOnLan` はいずれも **803** |
| `X_GetServiceStatus(Elements, ServiceName)` | 引数の語彙が不明で空だと **402** |

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

その他: `GetSortCapabilities` は `dc:title,dc:date,upnp:genre,av:capturedDateTime`、`GetSearchCapabilities` は
**空**（`Search` は使えない）。`X_HDLnkGetRecordDestinations` は `HDD` 1 つ。`X_GetDLNAUploadProfiles` は
アップロード可能な 6 プロファイルを返します。`GetSystemUpdateID` は変更のたびに増える番号です。

## ConnectionManager

`connectionmanager-answers.txt` に別途。要点は、送信 33 プロファイル・受信 0、録画は DTCP-IP 経由でしか
出てこないこと、`PrepareForConnection` が無いので接続管理は実質存在しないこと。
