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

### 予約を入れたのは誰か

`reservationCreatorID` で分かれます。実機（BDZ-FBT4100）で観測した 45 件の内訳は次のとおりで、2 つの値は
`mediaRemainAlertID` と完全に対応していました。

| `reservationCreatorID` | `mediaRemainAlertID` | 意味 |
|---|---|---|
| `2200` | `0` | ネットワーク越しのアプリが入れた予約（本ソフトや公式アプリ） |
| `1100` | `s01` | レコーダー自身が入れた予約。おまかせ・まる録の類 |

Video & TV SideView が「予約リスト」と「おまかせ予約リスト」を分けて見せるのはこの区別です。

おまかせの予約は `X_DeleteRecordSchedule` で消せますが、**消しても戻ってきます**。レコーダーがおまかせの一覧を
作り直すときに同じ番組を入れ直し、そのとき予約 ID が変わります。実機では 1 件消した直後は 44 件になり、
しばらく後には 45 件に戻っていて、同じ番組の ID が `0x...d38ac` から `0x...d38c9` に変わっていました。
止めるにはレコーダー本体でおまかせ録画の設定を変える必要があります。

作り直しは 1 件ずつではなく**おまかせの予約がまとめて振り直される**ことが分かりました。2026-09-15 の観測では、
42 件あった予約のうちおまかせの 19 件が一斉に新しい ID になり、番組（チャンネル・開始時刻・タイトル）はそのままで、
新規に選ばれた 3 件が加わって 44 件になっています。アプリ側が持っている `id` は数時間で無効になりうるので、
**削除の直前に一覧を取り直し、ID ではなく「チャンネル + 開始時刻」で同じ予約を引き直してから消す**のが安全です。
古い ID をそのまま送ると `804` が返り、画面上は正常な行を消そうとしただけに見えます。
アプリが入れた予約（`2200`）は振り直されません。

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
| 3倍 | 101 |
| AVC | 500 |

`3倍` と `AVC` は公式クライアントの表にある値で、本機（BDZ-FBT4100）には無いモードです。読めるようにはしてありますが、
予約に使えるのは上の 8 つだけです。

毎回録画 `scheduledConditionID`:

| 表示 | 値 |
|---|---|
| しない（単発） | `1` |
| 番組名（シリーズ追従） | `S001` |
| 毎日 | `d` |
| 毎週（月〜日） | `w1` 〜 `w7` |
| 月−金 | `w15` |
| 月−土 | `w16` |

`broadcastingType`: 地上デジタル `2`、BS `3`、110度CS `4`、BS4K `23`、CS4K `24`。公式クライアントの表にはほかに
`5`（124/128 度 CS と思われる）、`6`（CATV）、`10`（ひかりTV）、`101`（レコーダー内部のコンテンツ）がありますが、
本機では観測していません。

## おまかせ・まる録の条件（X_PvrControl）

レコーダー本体の「おまかせ・まる録」の条件は `X_GetPrefRecSettingList` で読めて、`X_CreatePrefRecSetting` /
`X_UpdatePrefRecSetting` / `X_DeletePrefRecSetting` で書けます。**4 つすべて実機で確認しました**（作成した条件は
確認後に削除）。

**`SearchCriteria` は無視されます。** 空、`*`、`presetID = "011"`、`type = "SEARCH"` など 7 通りで応答は
まったく同じでした（エラーにもなりません）。録画一覧・予約一覧では絞り込みが効くので、逆になっています。

**`Filter` は効きます。** 録画一覧・予約一覧の `Filter` は無視されますが、ここは違います。受け付けるのは
`*`、空、`desiredQualityMode`、`recordDestinationID`、`searchSetting` の 5 つだけで、ほかはすべて **803**。
空と `searchSetting` は同じ答え（条件の中身だけ）で、`desiredQualityMode` と `recordDestinationID` を足したいときは
その名前か `*` を渡します。**`*` を渡すこと**、でないと画質と録画先が黙って落ちます。

キーワードだけを登録した状態と、そこにジャンル・放送波・画質を足した状態の実機の応答（後者は `Filter` に `*`）:

```xml
<xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/">
  <object type="SEARCH" id="0x00001702">
    <searchSetting type="MULTIPLE" logic="OR">
      <name>サンプル</name>
      <keyword>サンプル</keyword>
      <timeScope>ALL</timeScope>
      <broadcastTypeScope>ALL</broadcastTypeScope>
    </searchSetting>
  </object>
</xsrs>
```

```xml
<xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/">
  <object type="SEARCH" id="0x0000470f">
    <desiredQualityMode>220</desiredQualityMode>
    <recordDestinationID>HDD</recordDestinationID>
    <searchSetting type="MULTIPLE" logic="AND">
      <name>クイズ/サンプル/テスト</name>
      <genreID type="2">0x50</genreID>
      <keyword>サンプル</keyword>
      <keyword>テスト</keyword>
      <excludeKeyword>ダミー</excludeKeyword>
      <timeScope>NIGHT</timeScope>
      <broadcastTypeScope>TRD</broadcastTypeScope>
    </searchSetting>
  </object>
</xsrs>
```

要素の順序は `name`、`genreID`、`keyword`（複数）、`excludeKeyword`（複数）、`timeScope`、`broadcastTypeScope` で
一定でした。`desiredQualityMode` と `recordDestinationID` は `searchSetting` より前、`object` の直下です。

`object` の `id` が `X_DeletePrefRecSetting` と `X_UpdatePrefRecSetting` の `SearchSettingID` です。
指定していない項目は要素ごと出てきません（1 つめの例に `genreID` が無いのはそのため）。

分かったことが 3 つあります。

- **`id` は条件を変えると振り直されます。** 同じ 1 件の条件を 2 回編集しただけで `0x00001702` →
  `0x00003701` → `0x0000470f` と変わりました。おまかせ予約の ID と同じ性質なので、**控えた
  `SearchSettingID` を後で使うのは危険**です。削除・変更の直前に一覧を取り直すこと。
- **`genreID` は 16 進です。** 値の作り方は予約の `genreID` と同じ（level1×16＋level2）ですが、予約は十進
  （`48`）、ここは `0x` 付きの 16 進（`0x50`）で書かれます。同じ名前の項目で表記が違う点に注意。`0x50` は
  level1=5（バラエティ）level2=0（クイズ）で、本体が付けた表示名「クイズ/サンプル」と一致しました。
  本体で大分類だけ（「バラエティ」全体）を選ぶと **`type="3"` の `0x5*`** になります。`*` が下位すべての印で、
  キーワード無しでジャンルだけの条件も作れます（本体でそう作った条件を読んだもの）。こちらから同じ形を送っても
  受理され、読み返しも同じ形で戻ります。
- **`name` はレコーダーが組み立てます。** ジャンルとキーワードを `/` でつないだもので、条件を足すたびに
  `サンプル` → `クイズ/サンプル` → `クイズ/サンプル/テスト` と変わりました。表示名として読むだけにして、
  識別子として使わないこと。
- **`broadcastTypeScope` は文字列コード**で、地上デジタル `TRD`、BS `BSD`、110度CS `CSD`、BS4K `ADVBSD`、
  CS4K `ADVCSD`。番組表ファイル名の綴り（`EPG_BSEPG_FILE.dat` の `BS`）とは違って末尾に `D` が付きますが、
  4K はファイル名と同じです。`ADVBSD` と `MIDNIGHT` は本体で設定したものを読み、`ADVCSD` はこちらから送って
  そのまま保持されることを確認しました。
- **知らない放送波は `ALL` に落ちます。** `NOSUCHWAVE` を送るとエラーにならず、できた条件は「すべての放送」に
  なりました。綴りを間違えると**いちばん広い設定**になる、ということです。

要素は本体の設定画面の項目に対応します。左が取説（2021 年 4K モデルの使いかたマニュアル）の呼び名です。

| 本体の条件 | 要素 | 備考 |
|---|---|---|
| キーワード（5 枠） | `keyword`（複数可） | 部分一致。`name` は条件そのものの表示名 |
| 除外ワード（2 枠） | `excludeKeyword`（複数可） | |
| キーワード検索方法 | `searchSetting` の `logic` 属性 | 「いずれかのキーワードを含む」= `OR`、「すべてのキーワードを含む」= `AND` |
| ジャンル | `genreID`（複数可、`type` 属性つき） | 16 進。`type="2"` で `0x50`（level1 と level2）、`type="3"` で `0x5*`（level1 だけ、下位はすべて）。下記 |
| 時間帯 | `timeScope` | 5 択。指定なしは `ALL` |
| 放送 | `broadcastTypeScope` | `ALL` / `TRD` / `BSD` / `CSD` / `ADVBSD` / `ADVCSD`。詳細設定に入る前に選ぶ |
| 対象チャンネル | `presetID`（複数可） | **この機種は返しません。** 下記 |
| 録画モード(地上/BS/CS) | `desiredQualityMode` | `object` 直下。上の録画モード表と同じ値 |
| 録画モード(BS4K/CS4K) | `desiredQualityModeForAdvanced` | 同じ。送らなければ `100`（DR）で埋まる |
| 録画先 | `recordDestinationID` | `object` 直下 |

本体の「時間帯」は任意の範囲ではなく、次の 5 つから選ぶものでした（境界は画面の表記のまま。意図的に重なって
います）。`ALL` 以外を送るときの綴りは未確認です。

| 画面 | 時刻 | 値 |
|---|---|---|
| すべての時間帯 | | `ALL`（実測） |
| 朝 | 5 時 − 12 時 | `MORNING`（実測） |
| 昼 | 11 時 − 6 時 | `AFTERNOON`（実測） |
| 夜 | 5 時 − 12 時 | `NIGHT`（実測） |
| 深夜 | 11 時 − 5 時 | `MIDNIGHT`（実測） |

5 つとも実機で確認しました。

### 条件を作る・変える・消す

| アクション | 引数 | 返り |
|---|---|---|
| `X_CreatePrefRecSetting` | `Elements`、`Format`（空） | `SearchSettingID` |
| `X_UpdatePrefRecSetting` | `Elements`、`Format`（空）、`SearchSettingID` | 新しい `SearchSettingID` |
| `X_DeletePrefRecSetting` | `SearchSettingID` | — |

`Elements` は一覧と同じ形です。作成では `object` に `id` 属性を付けず（予約の `<item id="">` とは違い、属性
そのものを省く）、変更では**現在の id を `object` に書き、`SearchSettingID` 引数にも同じ値を渡します**。
実際に通った作成の `Elements`:

```xml
<xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/">
  <object type="SEARCH">
    <desiredQualityMode>220</desiredQualityMode>
    <recordDestinationID>HDD</recordDestinationID>
    <searchSetting type="MULTIPLE" logic="OR">
      <name>（何を書いてもレコーダーが付け直します）</name>
      <keyword>キーワード</keyword>
      <timeScope>ALL</timeScope>
      <broadcastTypeScope>ALL</broadcastTypeScope>
    </searchSetting>
  </object>
</xsrs>
```

書き込みで分かったこと。

- **変更は id を振り直します。** `X_UpdatePrefRecSetting` の応答に**新しい** `SearchSettingID` が入って返って
  きました（`0x00006707` → `0x00007706`）。本体で編集したときと同じ挙動で、API 側からも確認できたことになります。
  返ってきた値を使うこと。
- **他の条件を作ったり消したりしても、既存の条件の id は変わりません。** 振り直されるのはその条件自身を
  変更したときだけです。
- **`name` は無視されます。** 送った文字列ではなく、レコーダーがキーワードとジャンルから組み直します
  （`ブリッジ変更試験` と `0x30` を送ったら `ブリッジ変更試験/国内ドラマ` が返りました。level2 の名前まで
  知っているので、こちらのジャンル表より細かい）。
- **画質は放送波ごとに 2 つあり、応答に出るのは条件が含む側だけです。** `desiredQualityMode` が本体の画面の
  「録画モード(地上/BS/CS)」、`desiredQualityModeForAdvanced` が「録画モード(BS4K/CS4K)」。`TRD` だけの条件では
  前者だけ、`ADVBSD` だけの条件では後者だけ、`ALL` では両方返ります（本体の画面には出ていない側も表示されるので、
  値が無いのではなく返さないだけ）。
- **送るときも条件が含む側に入れること。** `ADVCSD` の条件に `desiredQualityMode` で 220 を送ったら捨てられ、
  4K 側が既定の `100`（DR）になりました。`desiredQualityModeForAdvanced` に 220 や 230 を入れれば保持されます
  （4K が DR 固定ということはありません）。`ALL` の条件では両方送れて、片方だけ送ると 4K 側は `100` になります。
- **要素の順序は送ったとおりに保たれます。** 本体で作った条件は `genreID` が `keyword` より前でしたが、
  こちらが後ろで送ったものはそのまま後ろで返ってきました。順序は受理の条件ではないようです。

### 対象チャンネルだけは扱えません

**読めません。** 本体でこの条件のチャンネルを 1 局（地上デジタルの 011「NHK総合1」）に絞った状態でも、
`presetID` はどの `Filter` でも出てきません。公式 PC クライアントは `presetID` を複数読む作りになっているので
要素自体は規格にありますが、この機種はこのアクションで返しません。

**書けもしません。** `X_CreatePrefRecSetting` に `presetID` を入れて送ると**エラーにならずに通り**ますが、
できた条件を本体の画面で見ると「対象チャンネル: すべてのチャンネル」でした。保存もされていません
（`presetID` 付きで作った条件を読み返すと、`Filter` が `*` でも空でもその要素は出てきません）。**受理するふりを
して捨てています。** 試した送り方は 16 通りで、結果はすべて同じです。

- `presetID` の値として: `011`（本体の画面に出る 3 桁番号。NHK総合1）、`0x0400` / `1024`（service_id を 16 進 /
  10 進で）、`11`、`1`（リモコンのボタン番号。日本のレコーダーで「プリセット」が普通に指すもの）
- `presetID` を**複数並べて**（公式クライアントのパーサがリストで読む形）: `1` と `2`、`011` と `021`
- **32 ビットのビットマスク説**: `0x00000001` / `0x00000002` / `0x00000003`。画面がチェックボックスの一覧なので
  自然な読みですが、2 ビット立てたものも 1 ビットのものと区別が付かず、外れ
- **要素名の違い**: 予約と同じ `scheduledChannelID broadcastingType="2" channelType="2"`（`searchSetting` の中と
  `object` 直下の両方）、`presetID` に `broadcastingType` 属性を付けたもの、`searchSetting` の属性としての
  `presetID="011"`、`channelID`、`serviceID`

どれもエラーにならず、読み返しに出ず、本体の画面は「すべてのチャンネル」でした。これらを再度試す必要は
ありません。

**公式 PC クライアントも助けになりません。** `X_GetPrefRecSettingList` のパーサ（`presetID` を文字列のリストで
読む）は持っていますが、それを呼ぶコードがどこにもなく、おまかせ・まる録を LAN から扱っていません。

**他の経路もありません。** 1 件だけを引く宣言外のアクション（`X_GetTitleInfoExt` があるので同じ型を疑い、
`X_GetPrefRecSettingInfoExt` など 10 通り）はすべて **401**。`/XSRS` と `/XSRSExt` に投げても 401。
`searchSetting` が 2 つ並ぶ形や別の `object` も出てきません（公式クライアントは `searchSetting` をリストで
読む作りですが、この機種は常に 1 つ）。

結果として、LAN から扱えるのは対象チャンネル以外のすべてです。チャンネルで絞りたい人は本体でやる必要があります。

**そして書き戻すと絞り込みは消えます。これは実験で確認しました。** 本体で対象チャンネルを NHK総合 だけに絞った
捨てていい条件を作り、それを一覧で読んだままの形（`desiredQualityModeForAdvanced` も含めて）でキーワードだけ変えて
`X_UpdatePrefRecSetting` を送ったところ、本体の画面は「すべてのチャンネル」に戻っていました。読めない項目は
書き戻しで保たれません。**変更していいのは自分が作った条件だけ**、本体で作られた条件は読んで見せるだけにすること。
クライアントが「本体で作られた条件」を見分ける手段は無い（`name` はレコーダーが付け直す、id は編集で変わる）ので、
自分が作った条件の id を控えておき、それ以外は触らない、という実装になります。

LAN から作った条件は、本体の画面でもそのまま条件として見えます。キーワード・時間帯・検索方法・放送・録画先・
録画モードのすべてが送ったとおりに表示されることを実機で確認しました。

**まだ分からないもの**: `timeScope` の深夜の綴り、`broadcastTypeScope` の 4K の綴り、`object` の `type` は `SEARCH` 以外に何があるか、
`searchSetting` の `type="MULTIPLE"` の他の値、1 台に登録できる条件の数。

`X_GetPrefRecSettingList` が 0 件でも `reservationCreatorID` が `1100`（レコーダー自身）の予約は存在します。
この一覧に載るのは「おまかせ・まる録」の条件だけで、新番組おまかせ録画などの単発設定は別の仕組みです。

なお、詳細設定の記述方法はネットワーク経由で取得する、と取説にあります。公式 PC クライアントもキーワード一覧を
サーバーから落としてローカルに保存していて、突き合わせると同じ仕掛けに見えます。

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
実測した一覧は `upnp/service-sweep.md` にあります。

### 受信できないチャンネルは番組指定で予約できない（831）

`X_CreateRecordSchedule` に `desiredMatchingID` を付けて**受信契約のないチャンネル**を指定すると **831** が返ります。
実機（BDZ-FBT4100）での確認:

| 指定 | 結果 |
|---|---|
| 未契約の CS チャンネル ＋ `desiredMatchingID` | 831 |
| 同じ番組を `desiredMatchingID` なし（時刻のみ） | 作成できる |
| 未契約の BS チャンネル ＋ `desiredMatchingID` | 831 |
| 受信できる BS チャンネル ＋ `desiredMatchingID` | 作成できる |
| 地上デジタル（受信可）＋ `desiredMatchingID` | 作成できる |

録画モードは無関係でした（DR でも 831）。放送種別でもありません（受信できる BS は通る）。
`X_GetLiveChList` は未契約のチャンネルも返すので、**事前に受信可否は判定できません**。試して 831 を受け取り、
そのまま利用者に伝えるのが唯一の方法です。時刻指定でなら予約できますが、受信できない局を時間で録っても
スクランブルされた中身が残るだけなので、代替として勧めるべきではありません。

`desiredMatchingID` の形についても分かったことがあります。第 3 フィールド（サービス）は**実サービス ID でも
`0x0` でも通ります**（レコーダー自身が入れた予約はすべて `,,0x0,<event>`、捕獲した公式アプリの要求は
`,,0x428,<event>`）。一方、**形が壊れていると（フィールド数が足りない、16 進でない）エラーにならず、番組追従
なしの予約として作成されます**。番組を追いかけているつもりで時刻予約になっている、という失敗が起こり得ます。

## 録画タイトルが持つ項目（全列挙）

「レコーダーが番組単位のまとめを持っているなら、名前からの推測は不要になるはず」という問いに答えるため、
タイトルが持つ項目を全部列挙しました（2026-09-16、BDZ-FBT4100）。

`X_GetTitleList` の item（17 項目）:
`desiredQualityMode` `genreID` `lastPlaybackTime` `markingID` `portableRecordFile` `recordDestinationID`
`recordSize` `recordingFlag` `reservationCreatorID` `scheduledChannelID` `scheduledDuration`
`scheduledStartDateTime` `targetQualityMode` `title` `titleHevcFlag` `titleNewFlag` `titleProtectFlag`

`X_GetTitleInfoExt` の object（40 項目、上記に加えて）:
`autoCreatedFlag` `chapterTime` `dlnaFlag` `downloadFlag` `editCount` `eventDetail` `eventSummary`
`lastPlaybackDateTime` `longestDigestScene` `normalDigestScene` `shortestDigestScene` `odekakeSize`
`parentalRate` `pictstoryFlag` `playListFlag` `privateFlag` `recommendedFlag` `recordStartDate`
`remoteViewFlag` `rentalFlag` `resumePoint` `searchSetting` `startPTS` `titleSize` `userPlaybackTime`

**グループ・シリーズ・フォルダを指す項目はありません。** 番組単位のまとめは、レコーダーからは取れません。
`recorder/series.py` と `Series.swift` の名前ベースのグルーピングは近道ではなく、必要なものです。

分かったこと:

- **`autoCreatedFlag`** — 実機では `1` ⟺ `reservationCreatorID=1100`（レコーダー自身の録画）、`0` ⟺ `2000`。
  予約側の `reservationCreatorID` は作っていない予約に `2200` が付く例があって信用できませんが、こちらは
  その種の矛盾をまだ見ていません。「レコーダーが自分で録ったか」の判定はこれを使うほうが堅い。
- **`searchSetting`** — おまかせの条件を指すらしい項目ですが、実機では全タイトルで空。`X_GetPrefRecSettingList`
  が 0 件なのと整合します。
- **`eventSummary` / `eventDetail`** — `X_GetTitleDetail` で別に取っている番組説明と同じもの。両方要るなら
  `X_GetTitleInfoExt` 1 回で済みます（1 タイトル 1 リクエストなのは変わらない）。
- `titleSize` は MB、`odekakeSize` は桁からして KB。`recordSize`（一覧側）とは別項目。
- `dlnaFlag` / `remoteViewFlag` は配信可否。`recommendedFlag` は自動録画の一部に `1`。
