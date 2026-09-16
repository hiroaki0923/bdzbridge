# ネイティブアプリへの移植ガイド

bdzbridge はサーバー（Python）とブラウザ（PWA）で動いています。一般の利用者に配る形は、サーバーも VPN も要らず
アプリが LAN 上のレコーダーと直接話すネイティブアプリです。このドキュメントは、その移植で「何をそのまま持っていき、
何を作り直し、何で検証するか」をまとめたものです。プロトコルそのものの説明は [`xsrs-api.md`](xsrs-api.md) と
[`epg-format.md`](epg-format.md) にあり、ここでは繰り返しません。

読者は 2 通りです。

- **iOS アプリを作る人（作者）**: Swift / SwiftUI で書きます。下の「Swift での対応」と「App Store 申請の要点」がそのための節です。
- **他のプラットフォームに移植する人**: Android ネイティブは作者の予定にありません。必要と思った人が作れるように、
  機種依存の知識と検証ベクタは言語に依存しない形にしてあります。Android 利用者向けの現状の道は、サーバーを自分で
  動かして PWA を使うことです。

## 前提と方針

- レコーダーの API は LAN 内で無認証です。アプリはレコーダーと同じ LAN にいるときだけ動作し、宅外では
  キャッシュ済みの番組表を見て予約を「予約待ち」として溜め、帰宅後（LAN に戻ったとき）に反映します。
- Python のサーバーは移植中も動かし続け、**正解（oracle）**として使います。同じレコーダーに対して両方から
  同じ操作をして結果を突き合わせるのがいちばん確実な検証です（書き込みは予約の作成→削除で行い、録画の削除は
  テストに使わないこと）。
- 機種依存の知識はすべて `server/bdzbridge/recorder/` に閉じ込めてあります。移植の中心はこのディレクトリです。

## 何を持っていくか

| Python 側 | 役割 | 移植先での扱い | 検証ベクタ |
|---|---|---|---|
| `recorder/discovery.py` | SSDP M-SEARCH → 見つからなければ /24 を TCP 64220 でスキャン → `description.xml` で確認 | 必須。SSDP はマルチキャストの権限が要る（後述）。スキャンだけでも成立する | `port/description.json` |
| `recorder/client.py` | 1 台分の状態、EPG/ロゴのダウンロード、DLNA ツリーから配信ポートの検出、**全リクエストを直列化するロック** | 必須。ロックは絶対に省かない（並行リクエストに 503 を返す） | — |
| `recorder/xsrs.py` | SOAP の組み立て、予約/録画 item の解析、`build_create_elements` | 必須。生成する XML は Python とバイト単位で一致させる | `port/xsrs.json` |
| `recorder/codes.py` | 放送種別・画質・毎回録画・ジャンルのコード表、EPG/ロゴのファイル名 | そのまま定数に | `port/codes.json` |
| `recorder/epg.py` | EPG ファイルの復号（XOR 0x9D → 連結 zlib → @SRV/@DAY/@EVT）、ARIB 記号の置換 | 必須 | `port/epg-sample.{dat,json}` |
| `recorder/logo.py` | 局ロゴファイルの復号、PLTE/tRNS の挿入 | 任意（見た目） | `port/logo-sample.{dat,json}` |
| `recorder/series.py` | 録画タイトルからの番組名抽出（まとめ表示）、重複検出のキー | 必須（まとめ・重複を出すなら）。正規表現をそのまま移す | `port/series.json` |
| `recorder/wol.py` | Wake-on-LAN（MAC は ARP から） | 任意。スマホは ARP を読めないので、MAC は選択時に入力してもらうか諦める | — |
| `store/guide.py` | SQLite の番組表キャッシュ（検索用正規化、サブチャンネルの参照解決、放送日 04:00 区切り） | 端末内 DB に作り直す。仕様は下記「番組表の扱い」 | — |
| `store/rules.py` + `services/autorec.py` | キーワード自動予約 | 端末で番組表を更新したときに実行 | — |
| `services/titles.py` | 全録画リストのキャッシュ、まとめ、重複検出、一括削除/保護 | ロジックはそのまま。一括処理は端末内で逐次実行し、中止できるようにする | — |
| `jobs.py`, `api/`, `services/notify.py`, `services/monitor.py` | サーバーならではの部分（HTTP API、ジョブ、SMTP/webhook 通知、残容量監視） | 不要。通知は端末のローカル通知で代替 | — |

## Swift での対応

すべて OS 標準の機能で足ります。外部ライブラリは要りません。

| やること | 使うもの |
|---|---|
| LAN への HTTP と SOAP | `URLSession`。1 台につき 1 本に直列化するため、`actor` で包むか `OperationQueue` の同時実行数を 1 にする |
| /24 の TCP スキャン | Network framework の `NWConnection` を並列に張り、ポート 64220 が開いているホストを集める |
| SSDP | `NWConnection` のマルチキャスト。エンタイトルメント申請が必要なので後回しにする |
| Wake-on-LAN | `NWConnection` の UDP でブロードキャストアドレスへ送る |
| 連結 zlib の展開 | `libz` を直接使い、`z_stream` の未消費バイト数から次のストリームの開始位置を求める。`import zlib` がそのまま通り、iOS SDK でも解決します。Compression framework でも消費量は追えるが、境界の判定を自分で書くことになる |
| XML の解析 | `XMLParser`。SOAP 応答と DIDL-Lite の両方に使う |
| XML の生成 | 文字列連結で十分。要素の順序を固定したいので、汎用のシリアライザは使わない方が確実 |
| 番組表の保存 | SQLite。検索用に NFKC + casefold 済みの列を持たせる |
| 定期更新 | `BGAppRefreshTask`。呼ばれる保証がないので手動更新も必ず置く |
| 通知 | `UNUserNotificationCenter`。自動予約の結果と残容量の警告に使う |

UI で唯一手間がかかるのは番組表の表形式です。時間軸とチャンネル軸の 2 方向スクロール、両方向に残るヘッダー、
ピンチでの時間軸の拡大縮小は SwiftUI でも自前で組む必要があります。PWA 側の `GuideGrid.svelte` が仕様書代わりになります。

## レコーダーの振る舞いチェックリスト

実機（BDZ-FBT4100）で分かったこと。どれもコードにコメントとして残っていますが、移植時に踏みやすい順に並べます。

**通信**
- 同時リクエストは 503。1 台につき 1 本のキューで直列化する。
- XSRS の制御 URL は `/XSRS`、X_PvrControl は `/X_PvrControl`、ContentDirectory は `/DMSContentDirectory`。ポートは 64220。
- SOAP ヘッダは `Content-Type: text/xml; charset="utf-8"`、`SOAPACTION: "<serviceType>#<action>"`、`Accept-Language: ja`。
  本文の形は `port/xsrs.json` の `soap.example`。
- エラーは HTTP 500 + SOAP Fault の `errorCode`。402 は引数の形式違反（例: 時刻のオフセットが `+0900`）、820 は存在しない
  タイトル ID、880 はレコーダーがネットワークスタンバイ中で再生できない。
- EPG/ロゴのファイルは別ポート（既定 60151）から `//EPG_TRDEPG_FILE.dat` のように**スラッシュ 2 つ**で取る。ポートは
  DLNA ツリーの最初の `<res>` URL から確認できる。そのチャンネル種別を持っていない場合は 416 が返る。
- ネットワークスタンバイ中でも API は答える。電源を入れるのは `X_PowerControl` の `on`（`PowerOn` や `On` は不可）。
- レコーダーが完全に落ちている（電源オフ後しばらく）と何も答えない。Wake-on-LAN で起きる。本体の「ネットワーク待機」が
  切だと、しばらく操作がないだけで LAN から消えるので、これは例外ではなく普通に起きる。
- **Wake-on-LAN はレコーダー自身が申告しています。** `description.xml` の `X_WakeupOnLAN` が `1`（取説には記載なし、
  公式クライアントもこの値を読む）。
  宛先の MAC は 2 通りで取れるので、ユーザーに入力させる必要はありません。`X_PvrControl` の `X_GetPrivateIp` が
  `macAddress` と `wirelessMacAddress` を返すのが正攻法で、`description.xml` の `<UDN>` の末尾 12 桁も同じ有線 MAC です
  （`uuid:XXXXXXXX-XXXX-XXXX-XXXX-<MAC>`、実機で ARP と一致）。iOS は ARP を読めないので、起きているうちに控えておくのが
  唯一の手です。有線と無線で MAC が違うので、繋いでいる側を使うこと。
- **Wake-on-LAN は同じサブネットにいるときだけ確実です。** `255.255.255.255` はルーターを越えず、VPN 越しの端末は
  自分のインターフェースから自宅のサブネットを知ることができません。レコーダーのアドレスからそのサブネットの
  ブロードキャストを組み立てて送る手はありますが、ゲートウェイがディレクテッドブロードキャストを転送する設定で
  なければ届きません（UniFi は既定で転送しません）。**レコーダーのアドレス宛のユニキャストでも起きます**（実測:
  ブロードキャストを一切使わず、同じセグメントからアドレス宛にポート 9 と 7 へ送って 6 秒で応答）。
- **VPN 越しにも起きました。** 外出先から VPN でつないだ iPhone のアプリが、寝ていたレコーダーを起こして接続
  できています（寝てから 2 分後、起きるまで 2 分ほど）。届いたのはアドレス宛のユニキャストで、
  ブロードキャストは VPN を越えません。ただし**ゲートウェイがそのアドレスの MAC を覚えている間だけ**のはずで、
  何時間も寝たあとに同じことができるかは未確認です。キャッシュが切れた後は LAN の内側にいる何かに送ってもらう
  しかありません。自宅にサーバーを置いているなら `POST /api/v1/recorder/wake` がその役目を果たします。
- **この機種は ICMP に答えません。** 起きていても ping は通らないので、死活監視には使えません（UPnP のポート
  64220 に繋がるかで見ます）。「ping に答えない＝ネットワークにいない」とは言えない、ということでもあります。
  どちらの実装も、リミテッドブロードキャスト・サブネットのブロードキャスト・レコーダーのアドレスの 3 つへ送ります。
- `X_GetPrivateIp` は `useDhcp` も返します。アドレスが DHCP で動く機体なら、保存した IP に繋ぐだけの実装は取りこぼします。
  サーバー側は UDN で再探索していますが、移植先でも同じ手当てが必要です。
- サービスは 5 つに見えて実質 4 つ。`/XSRSExt`（`X_ScheduledRecordingExt:1`）は `/XSRS` と SCPD が完全に同一で、同じ答えを
  返します。詳細は `upnp/service-sweep.md`。

**予約**
- `X_CreateRecordSchedule` の `<Elements>` は公式アプリの送信内容と同一にする（`port/xsrs.json` の `create_elements[0]`
  は実キャプチャ由来）。要素の順序、`channelType="2"`、`scheduledChannelID` の `0x0428` 形式、時刻の `+09:00`。
- `desiredMatchingID` に `,,0x<service>,0x<event>` を入れると番組追従になり、タイトルはレコーダーが EPG から上書きする。
  時間指定（event なし）の予約は後から event_id が補完されることはない。
- 更新は同じ item に `id` を付けて `X_UpdateRecordSchedule`。画質・毎回録画をその場で変えられる。
- 毎週の毎回録画（`w1`〜`w7`）は番組の曜日と一致させる。
- 一覧は `X_GetRecordScheduleList`、1 回 200 件まで。ソートは `-scheduledStartDateTime`。
- `X_GetConflictList` に作成と同じ Elements を渡すと重なる予約が返る。

**録画タイトル**
- `X_GetTitleList` は `recordDestinationID=HDD` で検索し、1 回 200 件まで。`TotalMatches` を見て繰り返す。
- `lastPlaybackTime` は未再生だと本文が `notplayed`。`resumePoint` 属性が再生位置（秒）。
- `genreID` は ARIB のレベル1×16＋レベル2。
- `X_UpdateTitle` は `<item id>` と変える要素だけを送る（`titleProtectFlag`、`titleNewFlag`、`title`）。
- `X_DeleteTitle` は保護中なら失敗、**存在しない ID には成功を返す**。削除前に `X_GetTitleDetail` で存在を確かめる。
  1 件 3 秒ほどかかる。
- 再生は `X_PlayControlTitle`（`play` / `stop` / `pause`、小文字。`pause` はトグルで再開も同じ）。テレビ側で再生される。
- 残容量は ContentDirectory の `X_HDLnkGetRecordDestinationInfo`（バイト単位）。
- サムネイルは全タイトル共通のダミー画像なので出さない。番組内容は `X_GetTitleDetail`（summary と detail 群）。
- DLNA ツリーにはシリーズ ID がない。「まとめ」はタイトル文字列から `series.py` の規則で作る。公式クライアントも
  同じくクライアント側でタイトル文字列から鍵を作っている。
- レコーダー本体の「おまかせ・まる録」（キーワード自動録画）は `X_GetPrefRecSettingList` で読め、
  `X_CreatePrefRecSetting` / `X_DeletePrefRecSetting` で作成・削除できる。**変更は実装しない**: 一覧には本体で設定した
  対象チャンネルが含まれず、書き戻すとそれが消える（実測）。`Filter` は `*` を渡すこと。形と語彙は `xsrs-api.md`、
  ベクタは `port/xsrs.json` の `recorder_rules`。

**番組表**
- 時刻は 1970-01-01 00:00 **JST** 起点の秒（unix 時刻 + 32400）。
- サブチャンネル（例: 総合 2）の「参照」イベントは開始・終了と親の service/event しか持たない。表示時に親の番組を引く。
- ジャンルは 3 スロット（内容ニブル + ユーザーニブル）。
- テキストは UTF-8 だが NUL 詰めと C0 制御文字が混ざる。ARIB の私用領域文字は `codes.json` の `arib_symbols` で
  `[字]` 等に置き換え、それ以外の私用領域は捨てる。BS4K の一部外字はこの表で変換する（U+1F19B〜U+1F1AC）。
- 放送日は 04:00〜翌 04:00。
- ロゴファイルは毎日深夜に作り直される。受信していない局は 1152 バイトのゼロ。

## 端末側の設計メモ

- **番組表の扱い**: 5 種別 × 8 日分をまとめて取り、端末内 DB に置く。全文検索は NFKC + casefold した列で。更新は
  アプリ起動時と手動、それに OS のバックグラウンド更新（iOS の `BGAppRefreshTask` は不定期、Android の
  `WorkManager` は最短 15 分）に頼りすぎない。
- **予約待ちキュー**: LAN 外で入れた予約は端末に保存し、LAN に戻ったら順に `X_CreateRecordSchedule` する。番組表が
  古くなっている可能性があるので、反映時に同じ event_id が今の EPG にまだあるかを確認してから送る。反映結果は
  ローカル通知で知らせる。
- **LAN の判定**: 保存した UDN の `description.xml` が保存ホストで取れるか、駄目なら探索し直す（`services/session.py`
  の `resolve_recorder` と同じ順序）。
- **一括処理**: 削除・保護はキューで 1 件ずつ、進捗と「中止」を出す（中止は次の 1 件から止める）。アプリが
  バックグラウンドに回ると止まるので、その旨を表示する。
- **iOS の権限**: LAN への平文 HTTP は `NSAppTransportSecurity` の `NSAllowsLocalNetworking` で許可する。LAN
  アクセスの説明文 `NSLocalNetworkUsageDescription` も必須。SSDP のマルチキャスト送信には
  `com.apple.developer.networking.multicast` エンタイトルメントが要り、Apple への申請が必要。**TCP スキャンだけなら
  不要**なので、まずはスキャンで作る。
- **Android に移植する場合の権限**: `android:usesCleartextTraffic="true"` またはネットワークセキュリティ設定で LAN を
  許可し、SSDP には `WifiManager.MulticastLock` を取る。
- **Wake-on-LAN**: ブロードキャスト UDP はどちらの OS でも送れる。MAC アドレスは端末から ARP を読めず、
  `description.xml` にも入っていないので、レコーダーの本体設定画面に出る値を入力してもらう。任意機能にする。

## App Store 申請の要点

- **審査担当者はレコーダーを持っていません。** 起動しても何も見つからず、機能を評価できないという理由で返される
  可能性があります。これが最大のリスクです。ハードウェアなしで番組表と録画一覧が見えるサンプルデータのモードを
  必ず入れてください。ストア用のスクリーンショットにも使えるので、実際の番組情報を載せる必要もなくなります。
  審査メモに機種要件とデモ動画のリンクを添えるのも併せて効きます。
- **アプリ名は独自の名前にします。** 「ソニー BDZ 対応」はサブタイトルと説明文で伝えます。ロゴ、製品写真、
  本家アプリに似た配色やアイコンは使いません。
- **Info.plist** には `NSLocalNetworkUsageDescription` と `NSAllowsLocalNetworking` を入れます。用途は正直に書きます。
- **プライバシー**: ポリシーの URL は全アプリ必須なので、何も収集しない旨のページを用意します。App Privacy の
  質問票は収集項目なしで答えられます。`PrivacyInfo.xcprivacy` と、使うライブラリのプライバシーマニフェストが
  揃っていないとアップロードで弾かれるため、早めに一度通しておきます。
- **費用と手続き**: 個人登録で足ります。無料アプリなら銀行口座と税務情報の登録は不要です。iPhone のみにすると
  iPad 用のスクリーンショットと動作保証が不要になり、面倒が減ります。
- スクリーンショットの要求サイズは変わります。申請時に App Store Connect の最新の要件を確認してください。

Android を配布する人向けの注意も一つ書いておきます。Play ストアを使わず APK を直接配る形は、Play Protect の警告、
自動更新の欠如、そして認証済み端末へのサイドロードに開発者の本人確認を求める動きがあるため、一般利用者向けには
向きません。配布前に最新の要件を確認してください。

## 検証ベクタ（`docs/port/`）

`uv run python -m bdzbridge.tools.portkit` が Python 実装から生成します（テストが鮮度を確認するので、手で直さないこと）。
移植側では次のようなテストを書きます。

- `codes.json` — 定数の一致（コード表、ファイル名、ARIB 記号表、ロゴの共通カラーテーブル、名前空間、制御 URL）。
- `xsrs.json` —
  - `create_elements[*].input` から Elements 文字列を組み立て、`elements` と**完全一致**させる。
  - `update_elements` / `title_update_elements` も同様。
  - `parse_reservation.item` / `parse_title[*].item` を解析して `expected` と一致させる（`notplayed` の扱いを含む）。
  - `soap.example.body` と同じ本文を作れること。
- `description.json` — `description_xml` を解析して `expected` の各値（機種名、UDN、EPG 対応）を得ること。他社機や
  レコーダー以外のソニー機を弾くこと（製造者が Sony Corporation かつ XSRS サービスを持つもの）。
- `epg-sample.dat` → `epg-sample.json` — 復号結果が一致すること（時刻は ISO 8601 の `+09:00`、参照イベント、ジャンル、
  コピー制御、視聴年齢、記号置換）。実機ファイルでの検証は `server/tests/test_epg.py` の要領で自分のレコーダーから取る。
- `logo-sample.dat` → `logo-sample.json` — チャンネル番号と service_id の対応、ロゴのない局のスキップ、PLTE/tRNS 挿入後の
  PNG が `png_base64` と一致すること。
- `series.json` — `series_name` / `series_key` / `same_title_key` / `summary_key` の各値の一致。

## 進め方の案

0. **アプリの現状**: `app/BDBridge` に SwiftUI の 5 画面（番組表・検索・予約・録画・設定）があり、実機の
   iPhone で動いています。番組表はリストと表の両方、予約は作成・変更・削除、録画は一覧・まとめ・重複検出と
   一括削除/保護、検索は番組表と予約と録画の 3 つを対象にできます。レコーダーの自動探索、夜間の番組表更新、
   LAN から消えたレコーダーの Wake-on-LAN も入っています。`app/README.md` に起動方法と未実装の一覧があります。
1. プロトコル層: `description.xml` の解析 → SOAP 呼び出し → 予約一覧の取得（読み取りだけ）。`xsrs.json` と
   `description.json` を通す。**完了**: `app/RecorderKit` に XML ツリー、コード表、SOAP と Elements の生成、item の解析、
   `description.xml` の解析、そして HTTP クライアントがあります。`codes.json` / `xsrs.json` / `description.json` を
   通し、実機では予約一覧と残容量が Python サーバーと一致することを確認しました
   （`RECORDER_HOST=<ip> swift test --filter LiveRecorderTests`、読み取りのみ）。
2. EPG: ファイル取得と復号、端末内 DB、日別・チャンネル別の表示。`epg-sample` を通し、実機ファイルで Python と
   突き合わせる。**復号と端末内 DB まで完了**: `epg-sample` を通し、実機の地デジ 8266 件と BS 8709 件で
   Python 実装と全フィールドが一致しました（`RECORDER_EPG_DUMP=<dir> swift test --filter LiveRecorderTests` が
   書き出した行を突き合わせ）。`GuideStore` は同じ SQL で参照解決・検索正規化・04:00 区切りを行い、実機データで
   チャンネル数と番組数がサーバー側と一致します。8000 件の取り込みは Mac で約 60 ms。残りは表示（UI）。
3. 予約: 作成・更新・削除と番組追従。テスト用の予約名を決めて作成→削除で確認する。**API は実装済み**:
   `RecorderClient` に作成・更新・削除・重なり確認があり、送信するバイト列はスタブで検証しています。実機への
   書き込みはまだ行っていません。
4. 録画: 一覧、詳細、保護、削除、テレビ再生、まとめ、重複。`series.json` を通す。**まとめまで完了**:
   `Series.swift` が `series.json` を通し、実機の録画 1317 件で番組名・キーが Python 実装と全件一致し、
   同じ 150 グループになりました。重複検出はまだ移植していません。
5. 宅外: 予約待ちキューと LAN 復帰時の反映。
6. 仕上げ: キーワード自動予約、ロゴ、Wake-on-LAN、残容量の警告。**ロゴは完了**: 実機で地デジ 22 局、
   BS 65 局を復号し、Python 実装と同じ結果になりました。残容量の取得も実装済みです。

各段階で、Python サーバーの `docs/api.md` にある同じ操作を叩いた結果と比べると差分が見つけやすいです。
サンプルデータのモードは 2 の直後に作っておくと、実機がなくても UI を進められて申請にもそのまま使えます。
