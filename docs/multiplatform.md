# Android 版とマルチプラットフォーム化の調査（2026-09-28）

Android 版はないか、という問い合わせを受けての調査です。前提は、画面は各 OS のネイティブで作ること
（iOS は SwiftUI、Android は Kotlin）。そのうえで、今 `app/RecorderKit` にあるレコーダー側の部分をどう共有するかを
比べました。

[`porting.md`](porting.md) は、レコーダーの振る舞いと移植に必要な知識をまとめたものです。この文書は、それを
どう作るかの判断を残すものです。数字は、コードが変わるたびに、その時点のコードから数え直しています。一度出した結論は、コードと突き合わせて
反証を試み、直したものです。

## 結論

- **C/C++ の共通コアに JNI と Swift のラッパーを付ける案は採らない。** 理由は下の「採らなかった案」。
- **まず、Swift SDK for Android で RecorderKit をそのまま Android 向けにビルドしてみる。** 実装が一つのまま、
  既存のテストと `docs/port` のベクタがそのまま効く。止まる場所は下の表のとおりで、ほとんどは import と
  ライブラリの差し替えで済む見込み。
- **それが駄目なら、Kotlin で独立に実装する。** `porting.md` が想定している道で、`docs/port` のベクタと Python
  サーバーで正しさを確かめる。
- **AppModel の規則は、起こして待つ処理を 0.3 で RecorderKit にまとめた**（`Waking.swift`）。画面側と深夜の
  処理で二重に書かれていて、すでに食い違っていたため。そのあと、テストの無かった 4 つの規則（番組表が古いかの判定、
  採番し直された予約の探し直し、予約の要求の組み立て、送信待ちに送るものがあるかの判定）も移した。接続、諦め、
  ネットワーク変化の規則は、**判断**（`LinkRules.swift`）、**1 回の試みの順番**（`Reach.swift`）、**画面が読む
  状態**（`SessionState.swift`）を移し、最後に**接続そのもの**を、機器に共通の `DeviceLink.swift` とレコーダーに
  固有の `RecorderDriver.swift` に移した。AppModel に残るのは、画面の行と一覧、端末に保存するもの、通知、前面と
  背景の出入り、ネットワークと許可の見張り、一括処理の一時停止、LAN に出る口（`LinkEnvironment`）を作ること。
  画面の無い処理（深夜とショートカット）の試みも `RecorderDriver` にあり、マジックパケットの送り方だけをアプリが
  渡す。1 つの操作を作る部品（操作の前の確認とその理由、進行中の行、失敗の種類と文、失敗の伝え方）も
  `DeviceLink` に載せ（`LinkOperation.swift`）、レコーダーの操作の入口とテレビの一覧の読み込みが同じものを通る。
- **共有の規則は、レコーダーの型ではなく「何ができる機器か」に対して書く**（`DeviceEndpoint.swift`、
  `DeviceFailure.swift`）。起こして待つ処理、送信待ちの送信、番組表の更新は、確かめられる・送信待ちの 1 件を
  送れる・番組表を取れる機器なら何でも受け、エラーは機器に依らない分類で読む。送信待ちの 1 件をどう送るかは
  機器のもので（`QueueTarget`）、レコーダーの送り方は、作成の要求だけを持つ機器（`ReservationTarget`）の既定。
  レコーダー以外の機器を足すための継ぎ目で、レコーダーに対する動きは変わらない。
  テレビ（BRAVIA）の接続と登録も、同じ `DeviceLink` に載る
  `TVDriver` と、テレビとの通信の `ScalarClient` として RecorderKit にある。テレビの録画予約の一覧と削除も
  `TVDriver` の手順で（1 行の読みと、消す前に同じ予約かを確かめる規則は `TVSchedule`）、結果ごとの文もそこにある。
  アプリは返ってきた一覧を持ち、予約の行をその機器に振り分けるだけ。テレビに予約を入れるための 3 つの要求
  （局の一覧、録れなくなる予約の問い合わせ、作成）も `ScalarClient` にあり、送る中身のテレビ側の綴りは
  `TVReservation` にある。送信待ちの 1 件をテレビに送る手順（`QueueTarget` としての `ScalarClient`）も
  そこにある。テレビ宛の送信待ちをいつ送り、送っている間に何を出し、回が止まったときに何を言うかは `TVDriver` の
  手順（`sendWhatWaits`）。アプリのテレビのホストは、それを頼み、結果の文を持つだけ。
  テレビに予約を入れる、送信待ちの行を送り直すのも `TVDriver` の手順で（`reserve`、`resend`）、どちらも
  送信待ちに 1 行だけを送らせる。予約を入れた結果は、文ごと値で返る（`Reserved`。`LinkOperation.swift`）。
  ホストは頼んで、返ってきた一覧を持ち、「もう一度送る」は行の機器に振り分ける。
  送り直した行がどうなったかも同じ型で返り、行を出している画面に言い残したことがあるかも、待っている行を
  利用者に残すかも、その型が答える（`Reserved.besideItsRow`、`leftForTheReader`）。回が見たディスクの状態は、
  `TVDriver` がテレビについて知っていることに書く。
  画面に何を出すかを選ぶのはアプリのモデルで、帯が出す 1 行も、モデルが値で返す
  （`AppModel.strip(inSheet:)`）。
  番組の画面がテレビに何を出せるか（録るモード、その番組に送る繰り返し、入れられない番組とその文、録れなくなる
  予約があるときに聞く文）も `TVDriver` が答える。どの機器に入れられるかと、機器によらない 1 つの入口は、
  モデルにある（`AppModel.destinations(for:)`、`reserve(_:on:quality:repeating:)`）。

## 比べた案

| 案 | 判断 | 理由 |
|---|---|---|
| Swift SDK for Android で RecorderKit をビルド | まず試す | 実装が一つのまま。iOS アプリは変わらない。SDK は Swift 6.3（2026 年 3 月）で公式になったが、まだ experimental |
| Kotlin で独立に実装 | 確実な代わり | iOS に影響がない。Java の標準で NFKC（`Normalizer`）と後読みの正規表現が使える。ただし実装が 2 つになり、ベクタに無い規則（送信待ち、番組表の更新）は手で揃えることになる |
| Rust と UniFFI の共通コア | 共通コアを作るならこれ | SQLite と非同期まで持たせられる。3 つ目の言語になり、CI にも Rust が要る。UniFFI の async は Swift 6 の Sendable に対応しきっていない |
| C/C++ の共通コアと JNI、Swift ラッパー | 採らない | 下の「採らなかった案」 |
| Kotlin Multiplatform | 採らない | 動いている Swift の実装を捨て、iOS 側が利用者に回る。Swift export は 2026 年 8 月時点で Beta |

## RecorderKit の中身

47 ファイル、10,355 行（空行とコメントを含み、`Package.swift` を除く）。テストは 18,959 行。

| 区分 | 行数 | ファイル |
|---|---|---|
| 入出力を持たないロジック | 3,190 | Codes, Epg, Logo, Inflate, XsrsElements, XsrsParse, Soap, Xml, Series, Duplicates, Titles, Text, Models, Guide, RecorderTime, RecorderAddress, RecorderError, DeviceFailure, LinkRules, SessionState, Activities, TVSchedule, TVReservation |
| SQLite の上のもの | 1,028 | GuideStore, Sqlite |
| 非同期の段取り | 5,249 | RecorderClient, DeviceEndpoint, SerialQueue, PendingQueue, GuideRefresh, BulkWork, Discovery, ScanTally, Waking, Reach, DeviceLink, LinkOperation, RecorderDriver, ScalarClient, TVDriver, TVNoScreen, DemoTV |
| OS に縛られるもの | 888 | LocalNetwork, LocalNetworkAccess, WakeOnLan, Http, ScanLog |

本当に OS に縛られるのは 888 行だけです。SQLite はどちらの OS にもあり、番組表キャッシュの SQL はサーバーと同じ
ものです。非同期と SQLite まで持てる仕組み（Swift そのもの、または Rust）なら、RecorderKit の 9 割を共有できます。
共有の価値がいちばん高いのは、直列化キュー、503 の送り直し、取り消されても送信中の要求は待ち切る、といった
非同期の段取りです。C/C++ ではここがいちばん書きにくくなります。

RecorderKit の外、アプリ（10,081 行）にも端末側の規則があります。接続、起こす、諦める、ネットワークの変化は
RecorderKit に移しましたが（`DeviceLink`、`RecorderDriver`）、それを動かす側が残ります。前面と背景の出入り、
ネットワークの見張りと許可待ちの見張り、通知、一括処理の一時停止、画面の無い処理の段取り（いつ走らせ、何を送り、
何を取るか）で、AppModel（9 ファイルで 2,838 行、うち約 3 割がコメント。接続まわりは `AppModelSession.swift`）と、
BackgroundWork、Notify、SendWaitingIntent の 3 ファイル（合わせて約 670 行）です。RecorderKit だけを共有する
案では、どれを選んでもこれは Android で書き直します。

## どの案でも Android 側で作るもの

- 画面。とくに番組表の表形式（2 方向スクロール、両方向に残るヘッダー、ピンチ）。
- 上の端末側の規則。
- 定期更新。`WorkManager` で、最短 15 分。
- **ローカルネットワークの権限。** Android 17 は、LAN との通信に実行時権限 `ACCESS_LOCAL_NETWORK` を求めます。
  targetSdk 37 のアプリで必須で、LAN への直接の TCP と UDP も対象です。ネイティブのソケットからの送信は、権限が
  無いと EPERM で失敗するとされています。Google Play が targetSdk 37 を求める時期はまだ発表されていませんが、
  例年どおりなら 2027 年 8 月ごろで、実質的に必須になります。
  `porting.md` の「Android に移植する場合の権限」（平文の許可と MulticastLock だけ）は、この点で古くなりつつあります。
- 平文 HTTP の許可（`usesCleartextTraffic`）。Swift の URLSession は libcurl を使うので Java 側のポリシーは通りませんが、
  宣言はしておきます。
- 通知と、帰宅時に送信待ちを送る仕組み。
- 配布。Play ストアの登録、サイドロードの本人確認の動き（`porting.md` の「App Store 申請の要点」の末尾）。
- APK の大きさ。Swift で作る場合、Swift のランタイム、Foundation、ICU のデータを同梱する分だけ増えます。数値は未確認。

## Swift SDK for Android で試す場合

### ファイルごとの対応

コードを読んだうえでの見立てで、まだ実際にはビルドしていません。

| ファイル | Android で困ること | 扱い |
|---|---|---|
| LocalNetworkAccess | Network framework は Apple にしかない | Apple 専用のまま。Android の許可は Kotlin 側で扱う。`Access` の列挙型は共有できる |
| LocalNetwork | `import Darwin`。`sa_family` の比較が `UInt8`。`IFF_UP` などのフラグは Android では列挙型で、そのまま整数とビット演算できない。セルラーと VPN を外す名前の表が iOS 用 | Darwin、Android、Glibc の 3 分岐で import。`sa_family_t(AF_INET)` と書く。フラグは `.rawValue`。名前の表は OS ごと（Android は `wlan*`、`tun*`、`rmnet*`、`ccmni*`）。一覧の取得は Bionic の `getifaddrs` で足りる |
| WakeOnLan | `import Darwin`。`sin_len` が無い。`os.Logger` が無い | パケットの組み立てと宛先の選び方は共有。送信とログだけ OS ごと。Linux の Glibc では `SOCK_DGRAM` が列挙型なので、Linux でビルドするならそこも分岐 |
| ScanLog | `os.Logger` が無い | 走査のログの書き先だけ OS ごと。何を書くか（`ScanTally` の件数、アプリが組み立てる行）は共有できる。待ちの読みを書くのは LocalNetworkAccess で、Apple 専用のまま |
| RecorderAddress | IPv6 の判定に `inet_pton` と `in6_addr` を使っている。Apple の Foundation は Darwin を再エクスポートするが、Android の Foundation はしない見込み | 3 分岐で import |
| Sqlite | `SQLite3` は Apple のモジュール。Android の NDK はシステムの SQLite をアプリに公開していない | Android では SQLite のアマルガメーションを C ターゲットで同梱。C の API は同じなのでコードは変わらない。Linux はシステムの libsqlite3 で足りる |
| Inflate, Logo | `zlib` は Apple SDK のモジュール | 全 OS 共通の system library ターゲット 1 本で libz を読む。Logo が使うのは CRC32 だけなので、自前で書けば依存ごと外せる |
| Http | URLSession は FoundationNetworking にある | 条件付き import。libcurl が同梱される |
| Xml | XMLParser は FoundationXML にある | 条件付き import。libxml2 が同梱される |
| Series | `OSAllocatedUnfairLock` は Apple 専用。代わりの `Mutex` は iOS 18 からで、パッケージは iOS 17 対応 | `NSLock` に替える |
| Sqlite の文言 | 「iPhone の空き容量」 | 「端末の空き容量」 |

`RecorderTime` の `TimeZone(identifier: "Asia/Tokyo")` は、同梱の ICU のデータで解けるので変更は要らない見込みです。
Android の tzdata を読むのは、端末の現在のタイムゾーンを求めるときだけです。

残りのファイルはそのまま通る見込みです。`NSRegularExpression` はどちらも ICU、NFKC は Android の Foundation でも
`CFStringNormalize` なので、結果は同じはずです。違えば `docs/port` のベクタが検出します。

### テスト側

- `EpgVectorTests` と `LogoVectorTests` が SHA-256 の照合に CryptoKit を使っている。Android には無いので、swift-crypto に
  替えるか照合を外す。
- `SeriesRememberingTests` は `OSAllocatedUnfairLock`、`LocalNetworkAccessTests` は Network、`LogoVectorTests` は zlib を
  使っている。本体と同じ扱いにする。
- `Vectors.swift` はベクタの場所を `#filePath` から辿っているので、エミュレータでは見つからない。作業ディレクトリ
  からの相対パスにも探しに行くようにする。swift-android-action は、送ったファイルをパッケージの複製の中に置く。
- 実際のインターフェースに触るテストがある（`DiscoveryScanTests`、`XmlTests` の一部）。Android 用の一覧の実装が要る。
- `FileManager.default.temporaryDirectory` が Android で書ける場所を返すかは未確認。

### パッケージの分け方

- **一つのパッケージの中で、共有部を `RecorderCore` に分ける。** Foundation と C の薄い層にだけ依存させる。
- **Apple 用のターゲットは名前を `RecorderKit` のまま残し、`RecorderCore` を再エクスポートする。** アプリはすべて
  `import RecorderKit` で、`project.yml` はパッケージのパスとプロダクト名しか参照していない（ターゲット名は
  参照していない）ので、アプリは変わらない。
- **Android 専用の実装と同梱の SQLite は、別のローカルパッケージにする。** Android のときだけ依存させる
  （`.when(platforms: [.android])`）。同じパッケージに置くと、Mac の `swift test` がそれもビルドして、pre-commit
  フックと Xcode Cloud のアーカイブ前のテストが壊れるか遅くなる。`Package.swift` の中の `#if os(Android)` は
  ホスト側で評価されるので、この用途には使えない。
- **`#if` は、import の行と、OS に縛られる 3 ファイル（LocalNetwork、WakeOnLan、ScanLog）の中だけにする。**
- **静的な API はそのまま残し、インターフェース一覧の出どころだけを差し替えられるようにする。** アプリは
  `LocalNetwork` と `WakeOnLan` の静的関数を直接呼んでいる（AppModel、BackgroundWork、Surroundings、SettingsScreen）。
  `LocalNetwork.Interface` の公開の初期化子は足してある（アプリのテストが、作りものの Wi-Fi を渡すのに使う）。
- **置き場所は、Android を続けると決めるまで `app/RecorderKit` のまま。** 移すと `project.yml`、Xcode Cloud の
  スクリプト、pre-commit フック、CLAUDE.md がすべて変わる。
- **Kotlin への窓口は粗い単位で作る。** 接続、番組表の更新、予約の一覧と作成、送信待ちの送信といった関数を数個。
  Java 側は swift-java の jextract（JNI モード）が生成し、Swift の async は `CompletableFuture` になる。actor は
  final class で包み、受け渡しは単純な型か JSON にする。jextract がどの型まで扱えるかは、小さな例で先に確かめる。

### CI

- Xcode Cloud と pre-commit フックは今のまま。
- GitHub Actions はまだ無いので、足すなら二つ。Linux（Docker の Swift イメージ）での `swift test` は安く、Apple 専用の
  API が共有部に紛れ込んだのをすぐ見つける。skiptools の swift-android-action はエミュレータで `swift test` を回し、
  `copy-files` で `docs/port` を送れる。

### 進め方

1. Linux（Docker）で `swift test` を通す。Foundation、ICU、正規表現、XML の違いはここで全部出る。前もって、
   テストの CryptoKit を外し、Series のロックを NSLock に替え、Network を使うテストを Apple 限定にし、C の import を
   3 分岐にしておく。
2. Android SDK でビルドし、エミュレータでベクタのテストを通す。ここで残るのは、インターフェース一覧、WoL、zlib、
   SQLite だけのはず。通れば、復号や予約の組み立てが Apple 版と同じだと示せる。
3. ターゲットを分け、Android 専用のパッケージを作る。
4. Kotlin への窓口を作る。

## AppModel の規則

端末側の規則を共有部へ移すのは、Android で書き直す量がいちばん減る変更です。ただし出荷中のアプリの、いちばん
脆い部分の作り替えになります。AppModel は 70 回を超えるコミットで手が入り（`git log --follow`）、その多くは実機でしか
出なかった不具合の修正です。アプリのテスト（`BDBridgeTests`、187 件）がその再発を見張っています。

そこで、移植とは関係なく価値のある部分だけを先にやりました。起こして応答を待つ処理は、画面側
（当時の `AppModel.wakeAndAttach`）と深夜の処理とショートカット（`BackgroundWork.reach`）に二重に書かれていて、パケットを
送る順序、待つ長さ、取り消しの扱い、エラーで答えたときの扱いが食い違っていました。`PendingQueue` と `GuideRefresh` を
RecorderKit に移したのと同じ理由で、0.3 でこれを RecorderKit の `Waking.swift` にまとめ、`swift test` で確かめられる
ようにしました。待つ長さ（画面 30 秒、深夜とショートカット 60 秒）と取り消しの扱いは元のままで、深夜とショートカットも
マジックパケットを最初のプローブより前に送るようにしました。エラーで答えたときの扱いの違い（深夜側はエラーでも
起こして待つ）は残しています。

そのあと、AppModel にあってテストの無かった規則を 4 つ移しました。番組表が古いかの判定（レコーダーが深夜 1 時に
ファイルを作り直すより前に答えた種別は取り直す。`GuideRefresh.staleTypes`）、採番し直された予約の探し直し（id、
だめなら局と開始。`[Reservation].current`）、予約の要求の組み立て（変更では題名・時刻・局・番組 ID を保つ。
`ReservationRequest(program:)` と `(changing:)`）、送信待ちに送るものがあるかの判定
（`PendingQueue.hasSomethingToSend`）です。中身はそのままで、アプリは同じ場所からそれを呼びます。
続けて、重複検出で「本文を読めていない録画を候補から外す」安全規則（`Duplicates.readSets`）も移し、一括削除の
「レコーダーにもう無かった」を表示文言の比較ではなく結果の種類（`ItemOutcome.gone`）で見分けるようにしました。

同じときに、共有の規則がレコーダーの型（`RecorderClient`）を直接取るのをやめました。`Waking.waitForAnswer` は
確かめられる機器（`DeviceEndpoint`）を、`PendingQueue.flush` は予約できる機器（`ReservationTarget`。いまは
送信待ちの 1 件を送れる機器 `QueueTarget` で、下に書きます）を、
`GuideRefresh.run` は番組表を取れる機器（`GuideSource`）を取ります。エラーは `RecorderError` の述語ではなく、
機器に依らない分類（`DeviceFailure`: 無応答、混んでいる、この要求への断り、電源が要る、など）で読みます。
`RecorderClient` は今あるメソッドの上でこれらに適合するので、呼び出し側は変わりません。プロトコルに入れたのは、
いま共有の規則が使うものだけです。

接続、諦め、ネットワーク変化の規則は、画面の状態（エラーの一行、起動中の表示、許可待ちの印）と絡み合っています。
そこで先に、判断だけを状態を持たない関数にして RecorderKit に置きました（`LinkRules`）。接続が終わったときに
諦めるか（無応答のときだけ）、途中でネットワークが変わっていたら 1 回だけやり直すか、操作の前に確かめるか
（最後の応答から 90 秒）、アプリに戻ったときに何をするか（何もしない／ネットワークを見直す／接続する）、
開いている間にネットワークが変わったら何をするか、通知のあとに見直す間隔、の 6 つです。「どのネットワークで
最後に試したか、そのあと別のネットワークにいたか、何回試したか」は `LinkState` にまとめ、「試した」と
「ネットワークを見た」の 2 つの操作でしか変わらないようにしました。AppModel は判断をここに聞き、接続する、起こす、画面に出す、を
この時点ではまだ自分で行っていました。

続けて、1 回の試みの**順番**も移しました（`Reach`）。パケット → 短い確認 → 無応答なら許可を確かめる → 起こして
待つ → それでも無応答なら別のアドレスを探す、です。画面からの接続、操作の前の確認、深夜の処理とショートカットが、
それぞれ自分で並べていた順番でした。各段で何をするか（帯に出す行、レコーダーが自分について言うことの読み取り）は
呼び出し側が渡し、`Reach.run` は順番だけを持ちます。アプリのテストは LAN に何も出さないので、起こす・許可・
探し直しの順番には届きませんでしたが、段を記録するだけの偽物でここなら確かめられます。

最後に、画面が読む状態も移しました（`SessionState`）。レコーダーが自分について言ったこと、どの機体か（UDN。
無応答の間も残る）、無応答か、諦めたか、起こしている最中か、接続中か、許可待ちか、電源が要るか、何回つながったか、
MAC、どのネットワークで試したか、です。
AppModel の変数だったときは、どこからでも 1 つずつ書けたので、起きたことを半分だけ書くことができました（無応答に
なったのに説明を残す、許可待ちなのに諦めた印を付けない）。今は**起きたこと**でしか変わりません。説明が届いた
（`described`。控えている機体と UDN を比べ、初めて・同じ・別のどれかを返す。別なら、前の機体が自分について
言ったことを消してから置く）、無応答になった（`lost`、`wentSilent`）、接続の試みが終わった（`finishedTrying`）、
許可待ちになった（`waitingForPermission`）、別の機器を選んだ（`forgotTheDevice`。どの機体だったかも忘れる）
などで、それぞれが関係する値をまとめて正しい形に置きます。AppModel は同じ名前の読み取り専用のプロパティを
持つので、画面は今までどおり `model.gaveUp` のように読み、書くことはできません。`@Observable` なので、画面の
更新は値ごとに今までどおり起きます。

呼ぶ順番は呼び出し側（いまは `DeviceLink` と `RecorderDriver`）のもので、途中の食い違いは設計どおり残って
います。説明が届いた時点で接続済みになり、以前の無応答の印は残りを読み終える（`answered`）まで残ります。諦めた印は、次の接続が試み終わる（`finishedTrying`）
まで残ります。一覧を読み込むきっかけを「接続済み」だけにすると、この間に読みに行って空振りするので、画面は
「接続済みで、無応答でもない」をきっかけにします。

そのうえで、接続そのものを RecorderKit に移しました。機器に共通の `DeviceLink` が、接続、操作の前の確認、無応答と
諦め、アプリに戻ったとき、ネットワークの見直し、ローカルネットワークの許可を待つかどうか（下りるのを待つ見張りは
アプリが 1 つ持つ）を持ち、レコーダーに固有の手順は
`RecorderDriver` が持ちます（答えた機体の照合とキャッシュの引き継ぎ、接続のたびに読む値、起こして待つ、移った機体の
探し直し）。判断は `LinkRules`、順番は `Reach` のままです。アプリにしか持てないもの（画面の行と一覧、保存する
キー、一括処理、通知）に関わる所は、決まった時点で受け手（`LinkHost`。AppModel が受ける）に知らせます。LAN に出る
もの（通信、マジックパケット、許可の確認、移った機体の走査）は `LinkEnvironment` を通り、アプリが `Surroundings`
から作ります。サンプルデータのモードと背景で LAN に出さないことは、この口の側で決めています。

この移し替えは、アプリのテスト（77 件）を本体を変えずに通すことを条件にしました。そのために前の段で、テストを
AppModel の中の関数ではなく振る舞いで書き直してあります。アプリのテストは LAN に何も出さないので届かない規則
（パケットが最初の確認より前、許可待ちとそれを終わらせるもの、エラーで答えた機器は起こさない、起動待ちが答えずに
諦める、移った機体の探し直し）は、偽の外界を渡す RecorderKit の `DeviceLinkTests` が確かめます。リンクと
ドライバーに入れた変異（規則を 1 つずつ壊したもの）で、どちらのテストでも落ちないものが 1 つだけありました。
別のネットワークに出たあとの無応答で、ネットワークの見直しを始め直す規則です（移す前のコードでも同じでした）。
アプリのテストでは、通知が始めた見直しがまだ残っている間に無応答が来るので、始め直さなくても通っていました。
これも `DeviceLinkTests` で押さえました。レコーダー以外の機器を足すときは、同じ形のドライバーを書きます。

画面の無い処理（深夜の更新とショートカット）の試みも、そのあと `RecorderDriver` に移しました（`reachWithNoScreen`、
`isTheOneKnown`）。マジックパケットの送り方だけをアプリから受け取ります。アプリのテストはこの 2 つの処理に MAC を
渡せない（渡すと本物のパケットが出る）ので、起こして待つ部分には届いていませんでしたが、今は偽のパケットで
確かめています（`NoScreenReachTests`）。

さらに、1 つの操作を作る部品をリンクに載せました（`LinkOperation.swift`）。機器を確かめる、進行中の行を出す、
送る、失敗を伝える、という同じ手順が、レコーダーではアプリの操作の入口（`AppModel.run`）に、テレビでは
`TVDriver` に、2 回書かれていたためです。いまは、レコーダーの入口とテレビの予約一覧の読み込みが、`DeviceLink` の
同じ 1 つを通ります。操作の前の確認は、送れない
ときに理由を返します（`check`）。失敗は種類と文をまとめた値になり（`OperationFailure`）、それを画面に伝え、
無応答ならリンクを未接続・諦めた状態にするのが `say`、要求が 1 つの操作の順番が `run` です。機器によって
違うのは 2 つだけで、読み込みの無応答を受けるかどうかはドライバーが答え（`takesSilenceOnARead`）、書き込みの
あとの無応答に出す文は操作が渡します。この載せ替えも、アプリのテスト（122 件）と RecorderKit の既存の
テストを、本体を変えずに通すことを条件にしました。部品そのものは `LinkPartsTests` が偽の外界で確かめます。
レコーダーの個々の操作はまだ AppModel にあり、この部品の上に 1 つずつ移せます。

そのあと、送信待ちが「1 件をどう送るか」を持つのをやめました。`PendingQueue.flush` は、送信待ちの 1 件を
自分のやり方で送れる機器（`QueueTarget`）を取り、機器に 1 件ずつ送らせて、その結果（作った、すでにあった、
理由を付けて断った、見送った、この回はここまで）だけを読みます。送信待ちに残るのは、送る順番と、結果に応じて
行をどうするかです。レコーダーの送り方（作成を 1 回送り、無応答ならその回を打ち切り、理由の付いた断りは行に
書き、それ以外は見送る）は、`PendingQueue` から `ReservationTarget` の既定の実装へ移しました。写しは
作っていません。どの機器宛の行を受け取るかは機器の型が言うので（`QueueTarget.slot`）、別の機器宛の行を
渡す書き方はできません。結果の文も、アプリ（`Notify.swift`）から `PendingQueue.Outcome` の横へ移し、機器の
呼び名を受け取れるようにしました。この時点では、テレビに送る実装はありません。レコーダーだけの家では、送るものも文も
一字も変わらず、アプリのテスト（122 件）と RecorderKit の既存のテストは本体を変えずに通ります。テレビを
登録してある家で変わるのは、文がどの機器に送ったかを言うことだけです（「送信待ちだった「…」をレコーダーに
登録しました」。言うかどうかはアプリが決めます）。

テレビの送り方は、そのあと `ScalarClient` に書きました（規則は `porting.md` の「端末側の設計メモ」）。回の初めに
ディスクと一覧を読み、行ごとに、局の一覧、録れなくなる予約の問い合わせ、作成、一覧の順に送ります。送信待ちの側で
変えたのは 1 つだけで、機器が「作った」に文を添えられるようにしました（`RowSent.made(saying:)` と、結果の
`remarks`）。テレビは、作った予約がほかの予約に何をしたかを、作成の答えではなく一覧でしか言わないためです。
レコーダーは何も添えないので、文は一字も変わりません。この時点では、アプリは送信待ちにテレビを渡しておらず、
アプリのテスト（124 件）は本体を変えずに通ります。

そのあと、テレビ宛の送信待ちを送るようにしました。テレビに接続できたときと、予約一覧の引き下げ更新のときです。
送る前に端末の送信待ちを見て、送る行が無ければテレビには何も聞かないこと、送っている間の進行中の行、回が
止まったときに何を残して何を言うかは、`TVDriver` の手順です（`sendWhatWaits`。規則は `porting.md`）。この手順は
`DeviceLink.run` を通さず、その部品（進行中の行、操作の前の確認、失敗の伝え方）の上に書いてあります。送信は、回が
止まっても結果を返して終わるので、`run` を通すと、止まった回が前の失敗の行を消してしまうためです。アプリの側に
足したのは、テレビのホストがそれを頼んで結果の文を持つこと、帯がレコーダーの文とテレビの文を続けて言うこと、
レコーダーの送信をレコーダー宛の行があるときだけにすることです（テレビ宛の行しか無いときに、何も送らない
送信がテレビの回を待たないように）。レコーダーだけの家では、送るものも文も一字も変わらず、アプリの既存の
テスト（124 件）と RecorderKit の既存のテストは本体を変えずに通ります（アプリには、テレビ宛の行を送る
テストを 3 件と、テレビの無い家で帯が読む文のテストを 1 件足しました）。テレビ宛の行を作る画面は、
まだありません。レコーダーの送信の手順（`AppModel.flushPending`）は、まだアプリにあります。

そのあと、テレビに予約を入れる手順と、送信待ちの行を送り直す手順を `TVDriver` に書きました（`reserve`、
`resend`。規則は `porting.md`）。どちらも自分では作成を送らず、送信待ちに 1 行だけを送らせるので、テレビに
予約を作る道は、前の段の回のまま 1 つです。送信待ちの側に足したのは 2 つです。送る行を 1 件に
絞る口（`only`）と、同意を、行の id と利用者が同意した文の組で受け取ること（`consenting`。前は id の集合で、
渡す側はまだありませんでした）です。同意は文に対するものなので、行を送る番が来たときに、行の理由がその文と
同じかを送信待ちが確かめます。予約を入れた結果は、文ごと値で返します（`Reserved`。`LinkOperation.swift`）。
ドライバーの操作が値で返す最初の結果で、戸口で断ったことをどこで言うかの規則も、その型の説明に書きました。
レコーダーの予約の手順を移すときも、同じ型を返す形にします。アプリの側に足したのは、テレビのホストの 2 つの
入口（頼んで、返ってきた一覧を持ち、画面の送信待ちを読み直す）と、`AppModel.resend` の最初の 1 文（テレビ宛の
行をホストへ渡す）だけです。レコーダーだけの家では、送るものも文も一字も変わらず、アプリの既存の
テスト（128 件）は本体を変えずに通ります（アプリには 2 件足しました）。RecorderKit の既存のテストで本体を
変えたのは 1 件で、送信待ちに同意を渡すテストの引数 3 つを、id の集合から id と文の組に替えました。テレビに
予約を入れる画面は、まだありません。

そのあと、テレビ宛の送信待ちを画面がどう見せるかを、行を作る画面より先に揃えました（規則は `porting.md`）。
RecorderKit の側に足したのは 4 つです。送り直した行がどうなったかを、`TVDriver.resend` が `Reserved` で
返すこと。回が走れば予約を入れたときと同じ読み方で、走らなかった終わり方の分だけを足し、行そのものを出している
画面に言い残したことがあるかも、その型が答えます（`besideItsRow`）。接続が無応答に終わっても、作成や削除の
無応答の文を上書きしないこと。回が見たディスクの状態を、テレビについて知っていることに書くこと（止まれば
「無い」、初めの読み取りを通れば「ある」）。機器ごとに送信待ちを
消す口（`GuideStore.removePending(waitingFor:)`）。アプリの側に足したのは、状態を読んで、出すものを選ぶ
関数です。予約タブの行が言う機器の名前と、その下の説明（`deviceSaid`、`whatWaitsSays`）、画面が呼ぶ
送り直しと、送信待ちの行の削除の入口（`sendAgain`、`deleteWaiting`。`AppModel.resend` と `removePending` は
変えていません）、テレビを外すときにテレビ宛の行を先に消すこと（`takeTheTelevisionAway`。確認の文が
言った件数を受け取ります）、ディスクを待っている行があるか（`tvWaitsForItsDisk`）、そして帯が
出す 1 行の選び方（`AppModel.strip(inSheet:)`）です。帯の選び方は、それまで画面の中の条件の並びで、
テストから読めず、2 つを入れ替えてもどのテストも落ちませんでした。値にしたので、順番を `BDBridgeTests` が
確かめます。機器の文は `TVDriver` に、どの機器のことを言うかを選ぶ文はモデルにあります。レコーダーだけの
家では、画面も文も一字も変わらず、アプリの既存のテスト（130 件）と RecorderKit の既存のテストは本体を変えずに
通ります（アプリには 8 件、RecorderKit には 5 件足しました）。テレビ宛の行を作る画面は、まだありません。

そのあと、番組の画面からテレビに予約を入れられるようにしました（規則は `porting.md` の「番組の画面」）。
テレビ宛の行を作る最初の画面です。RecorderKit の側に足したのは、画面がテレビに何を出せるかを答える関数です。
テレビが録るモード（`recordsIn`）、その番組にテレビへ送る繰り返し（`repeats(for:)`。戸口が断るものと同じ
規則）、テレビに入れられない番組とその文（`whyNot`）、録れなくなる予約があるときに聞く文（`asks(of:)`）、
確認の最後の 1 文（`confirming`）です。アプリの側に足したのは、どの機器に入れられるか（`destinations(for:)`）、
機器によらない 1 つの入口（`reserve(_:on:quality:repeating:)`。レコーダーの予約は前の手順を 1 行も変えず、
その答えを `Reserved` に読みます）、機器ごとの送信待ちの行（`pending(for:on:)`）、録れなくなる
予約があるという問いへの「はい」と「いいえ」（`consent`、`decline`）です。問いへの答えをモデルに置いたのは、
いま入れたばかりの予約と、前から待っていた行とで扱いが違い（帯に出すか、行を消すか）、画面の中の
条件のままでは、テストから読めないからです。画面（`ProgramSheet`）は、欄がどの機器のものかを決め、
返ってきた `Reserved` の場合 1 つを、アラートの場合 1 つに読むだけです。待っている行を利用者に残すか（行に
理由が付いていて、言っている文がその理由ではない）も、同じ理由で、画面の中の比較から `Reserved` に移しました
（`leftForTheReader`。`besideItsRow` と同じ比較です）。画面には、この画面のほかの要求が返るまでテレビへの
要求を始めさせない数（`others`）を足しました。画面の中だけにある決まりは、テストから読めません
（`porting.md` の「テストが押さえていないこと」）。レコーダーの予約の手順（`AppModel.reserve`、`conflicts`、
`queue`）は、まだアプリにあります。ドライバーに移せば、入口の読み替えは 1 行になります。レコーダーだけの
家では、画面も文も一字も変わらず、アプリの既存のテスト（138 件）と RecorderKit の既存のテストは本体を変えずに
通ります（アプリには 5 件、RecorderKit には 5 件足しました。既存のテストに足したのは、行だけです。回の
テスト 1 件には場合を 1 つ、アプリのテスト 1 件には確かめる行を足しています）。

この変更は、はじめ、放送が始まった番組をテレビに送らない決まりも足していました。電源を切ったテレビが、
放送中の番組の作成で画面を点けるかどうかを、測っていなかったためです。戸口と回の両方で止め、回がいまの時刻を
読む時計をクライアントに持たせ、テストは自分の時刻をそこに渡していました。そのあと、この決まりを外しました
（`porting.md` の「測っていないこと」。レコーダーと同じに送り、本物のテレビが何をするかは、その版を初めて
使うときに確かめます）。決まりと一緒に、行に書く文、クライアントの時計、テストが時計を渡す行も消しました。
読むものが無くなったからです。回は、番組の時刻を時計と比べません。`whyNot` が答えるのは、放送の終わった
番組だけです。決まりを押さえていたテスト 3 件（RecorderKit に 2 件、アプリに 1 件）は、新しい決まりを
押さえるように書き直しました。ほかの既存のテストから消えたのは、時計を渡す行だけです。レコーダーだけの
家では、何も変わりません。

`SessionState` と `DeviceLink` は、メインアクターと Observation に縛られた型です（`RecorderDriver` と
`LinkEnvironment` もメインアクターのもの。ほかの共有の状態は値か actor）。iOS の画面の状態だからです。Linux と
Android でもビルドとテストは通る見込みですが、Kotlin の画面から読むには、メインアクターを Android の Looper で回すことと、変更を伝える橋渡しが要ります。それを作らない限り、
Android では画面側が自分の状態を持つことになります（進め方の 1、Linux での `swift test` で、Observation が
使えなければここで止まります）。

## 採らなかった案

**C/C++ の共通コア。** 必要なものが標準に無い。NFKC は ICU か utf8proc、まとめ規則の正規表現は後読みを使うので RE2 は
使えず PCRE2 か ICU、XML は expat か pugixml、HTTP は libcurl かプラットフォーム側へのコールバック。これを NDK と
SwiftPM の両方でビルドし続けることになる。さらに、共有する価値のある非同期の段取りを C の ABI の上で書き直し、
両側でラップし直すことになる。JNI の文字列は modified UTF-8 なので、補助面の文字（人名の「𠮷」など）はバイト列か
UTF-16 で渡す必要がある。ARIB の補助面の記号は、コアを出る前に `[4K]` のような ASCII に置き換わるので問題にならない。

**Kotlin Multiplatform。** 共有部が Kotlin になり、iOS は動いている Swift の実装を捨てて、それを使う側に回る。

**Rust と UniFFI** は、共通コアを別の言語で作るならいちばん筋が良い。Swift のまま Android でビルドできるなら、
その必要は無い。

## まだ確かめていないこと

- Android の Foundation が C のライブラリを再エクスポートしないこと。
- Android 11 以降でも `getifaddrs` が IPv4 のアドレスを返すこと。
- Swift 6.3 の公式 SDK に FoundationNetworking と FoundationXML が含まれること。
- swift-java の jextract が扱える型の範囲。
- Android の一時ディレクトリ。
- APK の増分。
- `ACCESS_LOCAL_NETWORK` の細部。公式ページは本文を読めず、検索結果の要約によっている。

## 出典

- Swift SDK for Android: [Announcing the Swift SDK for Android](https://www.swift.org/blog/nightly-swift-sdk-for-android/)、
  [Exploring the Swift SDK for Android](https://www.swift.org/blog/exploring-the-swift-sdk-for-android/)、
  [Getting started](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)、
  [Official Android support in Swift 6.3 (Skip)](https://skip.dev/blog/swift-63-android-support/)、
  [Porting Swift Packages to Android (Skip)](https://skip.dev/docs/porting/)、
  [finagolfin/swift-android-sdk](https://github.com/finagolfin/swift-android-sdk)
- Foundation: [swift-corelibs-foundation](https://github.com/swiftlang/swift-corelibs-foundation)、
  [swift-foundation](https://github.com/swiftlang/swift-foundation)
- Android の定数の型: [swift-nio NIOPosix/System.swift](https://github.com/apple/swift-nio/blob/main/Sources/NIOPosix/System.swift)
- swift-java: [swift-java](https://github.com/swiftlang/swift-java)、
  [JNI mode](https://forums.swift.org/t/gsoc-2025-new-jni-mode-added-to-swift-java-jextract-tool/81858)、
  [async と CompletableFuture（FFM モードへの追加。JNI モードには先にあった）](https://github.com/swiftlang/swift-java/pull/870)
- CI: [skiptools/swift-android-action](https://github.com/skiptools/swift-android-action)
- Android のローカルネットワーク権限: [Local network permission](https://developer.android.com/privacy-and-security/local-network-permission)、
  [Behavior changes: Android 17](https://developer.android.com/about/versions/17/behavior-changes-17)、
  [dart-lang/sdk#63272](https://github.com/dart-lang/sdk/issues/63272)、
  [Target API level requirements](https://developer.android.com/google/play/requirements/target-sdk)
- Android と SQLite: [SQLite Android bindings](https://sqlite.org/android/doc/b9019bf04f/www/install.wiki)
- `getifaddrs` の制限: [getifs](https://docs.rs/getifs/latest/getifs/)、[QTBUG-86394](https://bugreports.qt.io/browse/QTBUG-86394)
- JNI の文字列: [modified UTF-8 の問題の例](https://github.com/Thrameos/java-cef/pull/1)
- UniFFI: [uniffi-rs](https://github.com/mozilla/uniffi-rs)
- Kotlin Multiplatform: [Swift export](https://kotlinlang.org/docs/native-swift-export.html)、[Kotlin roadmap](https://kotlinlang.org/docs/roadmap.html)
