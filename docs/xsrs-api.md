# レコーダーの予約 API（UPnP X_ScheduledRecording / X_PvrControl）

Sony BDZ シリーズ（確認機種: BDZ-FBT4100、ファーム 35.003.1）が LAN 内に公開している UPnP サービスの、本プロジェクトで使う範囲の仕様。ソニー非公式。相互運用のために観察した振る舞いをまとめたもので、機種やファームで差がある可能性がある。

## 概要

- ポート `64220` に UPnP MediaServer がある。`GET /description.xml` にサービス一覧、`s-bras:productName`（機種名）、`s-bras:EPG_CAP`（番組表提供の可否）が入る（`docs/upnp/description.xml`）。
- 認証は無い。LAN 内なら誰でも呼べるので、ブリッジは LAN の外に公開しない。
- 同時に複数の要求を送ると 503 を返すことがある。要求は直列化する。
- ネットワークスタンバイ中も応答する。
- サービス（SCPD は `docs/upnp/`）:
  - `urn:schemas-xsrs-org:service:X_ScheduledRecording:2` — 制御 URL `/XSRS`。予約と録画済みタイトル。
  - `urn:schemas-xsrs-org:service:X_ScheduledRecordingExt:1` — `/XSRSExt`。同じアクション群。
  - `urn:schemas-s-bras-org:service:X_PvrControl:1` — `/X_PvrControl`。状態取得、電源、リモコンキー等。
  - `urn:schemas-upnp-org:service:ContentDirectory:1` — 録画済みタイトルと「放送中番組」の DLNA 階層。数日分の番組表は無い（番組表は `epg-format.md`）。

## 呼び出し方

通常の UPnP SOAP。`POST <controlURL>`、ヘッダー `Content-Type: text/xml; charset="utf-8"`、`SOAPACTION: "<serviceType>#<action>"`。応答の `Result` には XML 文字列（エスケープ済み）が入る。名前空間は `urn:schemas-xsrs-org:metadata-1-0/x_srs/`。

## X_ScheduledRecording のアクション

| アクション | 引数 | 用途 |
|---|---|---|
| `X_GetRecordScheduleList` | SearchCriteria, StartingIndex, RequestedCount, SortCriteria（例 `-scheduledStartDateTime`）, Filter（`*`） | 予約一覧 |
| `X_CreateRecordSchedule` | Elements | 予約作成。`RecordScheduleID` を返す |
| `X_UpdateRecordSchedule` | Elements（`id` 付き） | 予約変更 |
| `X_DeleteRecordSchedule` | RecordScheduleID | 予約削除 |
| `X_GetConflictList` | Elements | 作成前の競合確認。重なる既存予約の item を返す（無ければ空） |
| `X_GetTitleList` | SearchCriteria（例 `recordDestinationID=HDD`）, … | 録画済みタイトル一覧 |
| `X_DeleteTitle` | TitleID | 録画済みタイトルの削除（保護中は失敗） |
| `X_UpdateTitle` | Elements | 録画済みタイトルの変更。`<item id="…">` に変更したい要素だけを入れる: `title`, `titleProtectFlag`（0/1、保護）, `titleNewFlag`, `markingID` |
| `X_DeleteTitle` / `X_UpdateTitle` | TitleID / Elements | 録画済みタイトルの削除・更新（本プロジェクト未使用） |

## 予約 item の形式

作成に必要な最小形（`Elements` の値。SOAP 引数としてエスケープして送る）:

```xml
<xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/"><item id="">
  <title>番組名</title>
  <scheduledStartDateTime>2026-09-17T21:00:00+09:00</scheduledStartDateTime>
  <scheduledDuration>3600</scheduledDuration>
  <scheduledConditionID>1</scheduledConditionID>
  <scheduledChannelID broadcastingType="2" channelType="2">0x0428</scheduledChannelID>
  <desiredMatchingID type="SI_PROGRAMID">,,0x428,0x311f</desiredMatchingID>
  <desiredQualityMode>240</desiredQualityMode>
  <priorityFlag>0</priorityFlag>
  <recordDestinationID>HDD</recordDestinationID>
  <portableRecordFile target="preselect" transferPath="none"></portableRecordFile>
</item></xsrs>
```

| 要素 | 意味 |
|---|---|
| `item@id` | 作成時は空文字。更新時は既存の RecordScheduleID |
| `scheduledStartDateTime` | 開始時刻。タイムゾーンは `+09:00` の形式でなければならない（`+0900` は 402 で拒否） |
| `scheduledDuration` | 秒 |
| `scheduledConditionID` | 毎回録画の種別（下表） |
| `scheduledChannelID` | `broadcastingType`（下表）と `channelType="2"`。値は ARIB の service_id を 4 桁の 16 進で（`0x0428`） |
| `desiredMatchingID` | `,,0x<service_id>,0x<event_id>`（16 進、桁詰めなし）。付けると番組追従（放送時間の変更に追従）になる。省略すると時刻指定 |
| `desiredQualityMode` | 録画モード（下表） |
| `genreID` | ジャンル。ARIB コンテント記述子の先頭ペアを level1×16＋level2 の十進で持つ（48 = ドラマ、112 = アニメ／特撮など）。予約にも録画済みタイトルにも付く。`type` 属性は放送種別 |
| `priorityFlag`, `recordDestinationID`, `portableRecordFile` | 上記の値で固定。省略すると 402 |

振る舞い:
- `desiredMatchingID` を付けて作成すると、`title` はレコーダー自身の番組表の番組名で上書きされる。
- 時刻指定で作成した予約に、レコーダーが後から event_id を補うことはない。
- 一覧の item には上記に加えて `conflictID`、`recordingFlag`（録画中）、`reservationCreatorID`、`recordSize`（MB）などが付く。一覧に付く `mediaRemainAlertID`・`recordSize`・`portableRecordFile`（値付き）などを作成要求に含めると 402 になる。

### コード表

録画モード `desiredQualityMode`:

| 表示 | 値 |
|---|---|
| DR | 100 |
| XR | 210 |
| XSR | 220 |
| SR | 230 |
| LSR | 240 |
| LR | 250 |
| ER | 260 |
| EER | 270 |

毎回録画 `scheduledConditionID`:

| 表示 | 値 |
|---|---|
| しない（単発） | `1` |
| 番組名（シリーズ追従） | `S001` |
| 毎日 | `d` |
| 毎週（月〜日） | `w1` 〜 `w7` |
| 月−金 | `w15` |
| 月−土 | `w16` |

`broadcastingType`: 地上デジタル `2`、BS `3`、110度CS `4`、BS4K `23`、CS4K `24`。

## X_PvrControl（使用しているもの）

| アクション | 備考 |
|---|---|
| `X_GetPlayStatus` | `powerstatus`（`PowerOn` / `PowerInternalOn`=ネットワークスタンバイ）と `playstatus` |
| `X_GetFirmwareVersion` | `version` |
| `X_PowerControl(Operation)` | `on` で電源オン（`PowerOn`、`On` は 803） |
| `X_GetLiveChList(BroadcastType, SkipChannel)` | チャンネル（service_id）の `_` 区切り一覧。BroadcastType は 2/3/4 |
| `X_InputRemoteKey(RemoteKey)` | リモコンキー送信。確認済みのキー名: `BACK`, `CH_UP`, `PROGRAM_LIST`, `TITLE_INFO` |
| `X_GetTitleDetail(Id)` / `X_GetTitleInfo(TitleID)` | 録画済みタイトルの番組内容 / チャプター情報 |
| `X_GetMediaInfo(recordDestinationID)` | `remain`（MB）と `total`（MB）。バイト単位が欲しいときは ContentDirectory の `X_HDLnkGetRecordDestinationInfo(RecordDestinationID)` が `totalCapacity` / `availableCapacity` を返す |
| `X_PlayControlTitle(TitleID, Operation, Position)` | レコーダーに接続したテレビで再生。Operation は小文字の `play` / `pause` / `stop`（`pause` は再送で再生に戻るトグル。`resume` は 803）。`play` に Position を付けても先頭から始まる。ネットワークスタンバイ中は 880 |

エラーコード: 401 Invalid Action、402 Invalid Args（形式不正）、501/701 該当なし、803/820 アクション失敗。
