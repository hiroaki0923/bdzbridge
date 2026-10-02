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
  状態**（`SessionState.swift`）を移した。各段ですること（帯に出す行、読み取り、クライアントの持ち方）は、まだ
  AppModel にある。
- **共有の規則は、レコーダーの型ではなく「何ができる機器か」に対して書く**（`DeviceEndpoint.swift`、
  `DeviceFailure.swift`）。起こして待つ処理、送信待ちの送信、番組表の更新は、確かめられる・予約できる・番組表を
  取れる機器なら何でも受け、エラーは機器に依らない分類で読む。レコーダー以外の機器を足すための継ぎ目で、
  レコーダーに対する動きは変わらない。

## 比べた案

| 案 | 判断 | 理由 |
|---|---|---|
| Swift SDK for Android で RecorderKit をビルド | まず試す | 実装が一つのまま。iOS アプリは変わらない。SDK は Swift 6.3（2026 年 3 月）で公式になったが、まだ experimental |
| Kotlin で独立に実装 | 確実な代わり | iOS に影響がない。Java の標準で NFKC（`Normalizer`）と後読みの正規表現が使える。ただし実装が 2 つになり、ベクタに無い規則（送信待ち、番組表の更新）は手で揃えることになる |
| Rust と UniFFI の共通コア | 共通コアを作るならこれ | SQLite と非同期まで持たせられる。3 つ目の言語になり、CI にも Rust が要る。UniFFI の async は Swift 6 の Sendable に対応しきっていない |
| C/C++ の共通コアと JNI、Swift ラッパー | 採らない | 下の「採らなかった案」 |
| Kotlin Multiplatform | 採らない | 動いている Swift の実装を捨て、iOS 側が利用者に回る。Swift export は 2026 年 8 月時点で Beta |

## RecorderKit の中身

36 ファイル、5,205 行（空行とコメントを含み、`Package.swift` を除く）。テストは 5,313 行。

| 区分 | 行数 | ファイル |
|---|---|---|
| 入出力を持たないロジック | 2,655 | Codes, Epg, Logo, Inflate, XsrsElements, XsrsParse, Soap, Xml, Series, Duplicates, Titles, Text, Models, Guide, RecorderTime, RecorderAddress, RecorderError, DeviceFailure, LinkRules, SessionState, Activities |
| SQLite の上のもの | 958 | GuideStore, Sqlite |
| 非同期の段取り | 1,070 | RecorderClient, DeviceEndpoint, SerialQueue, PendingQueue, GuideRefresh, BulkWork, Discovery, Waking, Reach |
| OS に縛られるもの | 522 | LocalNetwork, LocalNetworkAccess, WakeOnLan, Http |

本当に OS に縛られるのは 522 行だけです。SQLite はどちらの OS にもあり、番組表キャッシュの SQL はサーバーと同じ
ものです。非同期と SQLite まで持てる仕組み（Swift そのもの、または Rust）なら、RecorderKit の 8 割以上を共有できます。
共有の価値がいちばん高いのは、直列化キュー、503 の送り直し、取り消されても送信中の要求は待ち切る、といった
非同期の段取りです。C/C++ ではここがいちばん書きにくくなります。

RecorderKit の外、アプリ（8,389 行）にも端末側の規則があります。接続、起こす、諦める、ネットワークの変化、
一括処理の一時停止で、AppModel（8 ファイルで 2,442 行、うち約 3 割がコメント。接続まわりは
`AppModelSession.swift`）と BackgroundWork、Notify、SendWaitingIntent を
合わせて約 1,200 行です。RecorderKit だけを共有する案では、どれを選んでもこれは Android で書き直します。

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
- **`#if` は、import の行と、OS に縛られる 2 ファイル（LocalNetwork と WakeOnLan）の中だけにする。**
- **静的な API はそのまま残し、インターフェース一覧の出どころだけを差し替えられるようにする。** アプリは
  `LocalNetwork` と `WakeOnLan` の静的関数を直接呼んでいる（AppModel、BackgroundWork、Surroundings、SettingsScreen）。
  `LocalNetwork.Interface` には公開の初期化子を足す。
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
出なかった不具合の修正です。アプリのテスト（`BDBridgeTests`、64 件）がその再発を見張っています。

そこで、移植とは関係なく価値のある部分だけを先にやりました。起こして応答を待つ処理は、画面側
（`AppModel.wakeAndAttach`）と深夜の処理とショートカット（`BackgroundWork.reach`）に二重に書かれていて、パケットを
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
確かめられる機器（`DeviceEndpoint`）を、`PendingQueue.flush` は予約できる機器（`ReservationTarget`）を、
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
今までどおり自分で行います。

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

呼ぶ順番は今までどおり呼び出し側のもので、途中の食い違いは設計どおり残っています。説明が届いた時点で接続済みになり、
以前の無応答の印は残りを読み終える（`answered`）まで残ります。諦めた印は、次の接続が試み終わる（`finishedTrying`）
まで残ります。一覧を読み込むきっかけを「接続済み」だけにすると、この間に読みに行って空振りするので、画面は
「接続済みで、無応答でもない」をきっかけにします。

`SessionState` は、RecorderKit の中でただ 1 つ、メインアクターと Observation に縛られた型です（ほかの共有の状態は
値か actor）。iOS の画面の状態だからです。Linux と Android でもビルドとテストは通る見込みですが、Kotlin の画面から
読むには、メインアクターを Android の Looper で回すことと、変更を伝える橋渡しが要ります。それを作らない限り、
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
