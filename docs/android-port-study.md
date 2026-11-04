# Android への移植の検討

RecBridge の iOS アプリを Android に持っていけるか、とくにレコーダーとテレビに話す層の `app/RecorderKit` を
どう持っていくかを検討したものです（2026-11-04、main 6f65a255 の時点）。移植一般の手引きと機種の癖は
[`porting.md`](porting.md) にあり、ここでは繰り返しません。

## 結論

- **RecorderKit は Swift のまま Android 向けにビルドする道が、開発の総量がいちばん少ない見込みです。**
  Apple にしかないモジュールを使うのは 61 ファイルのうち 8 ファイルで、どれも小さな差し替えで済みます。
  ほかに、iOS の `URLSession` の癖に合わせた 2 ファイルを Android で測り直します。
  残りは Foundation と標準ライブラリ（async/await、actor、Observation）だけで書いてあります。
- Kotlin で書き直すと、RecorderKit とアプリのモデルを合わせて約 25,000 行と、そのテストを二重に持つことになります。
  以後、レコーダーやテレビの振る舞いを直すたびに、Swift と Kotlin（とサーバーの Python）を直すことになります。
- 画面はどの道でも Android 用に作ります（または Skip で SwiftUI を Jetpack Compose に写します）。ここがいちばん大きい仕事です。
- **まだ確かめていないのは、Android 用の Swift SDK で RecorderKit が実際にビルドでき、動くかどうか**です。
  試すにはツールチェーン、SDK、NDK のダウンロードが要ります（下の「最初の一歩」）。

## 規模

| 部分 | 行数 |
|---|---|
| RecorderKit のソース（61 ファイル） | 19,515 |
| RecorderKit のテスト | 36,659 |
| アプリのモデル（`AppModel`、`RecorderHost`、`TVHost`、深夜の処理、保存、通知など） | 約 5,700 |
| アプリの画面（SwiftUI） | 約 6,000 |
| アプリのテスト（`BDBridgeTests`） | 25,205 |

RecorderKit には外部の依存がありません（`Package.swift` は自分のターゲットとテストだけ）。

## RecorderKit の中で Android に合わせるところ

| ファイル | 頼っているもの | Android では |
|---|---|---|
| `Inflate.swift`、`Logo.swift` | `import zlib`（Apple の SDK にあるモジュール） | zlib は NDK の安定 API にある。モジュールの定義（SwiftPM の `systemLibrary`）を 1 つ足す |
| `Sqlite.swift` | `import SQLite3`（OS の SQLite） | Android の SQLite は NDK に公開されていない。SQLite のソース（amalgamation、パブリックドメイン）をパッケージに入れて一緒にビルドする |
| `LocalNetwork.swift` | `Darwin` の `getifaddrs` | Android の C ライブラリにもある（API 24 から）。`sa_family` を `UInt8` と比べている 1 行は直す（Linux 系では 16 ビット） |
| `WakeOnLan.swift` | `Darwin` のソケット、`os.Logger` | ソケット（`SO_BROADCAST`、`sendto`）はそのまま。ログは差し替える |
| `ScanLog.swift` | `os.Logger` | ログを差し替える |
| `Series.swift` | `OSAllocatedUnfairLock` | パッケージのほかの所と同じ `NSLock` にする |
| `LocalNetworkAccess.swift` | Network framework の `NWConnection`（iOS のローカルネットワークの許可を、接続の状態から読む） | iOS だけの回り道。Android の許可は状態を直接読める（下の「ローカルネットワークの許可」）ので、ファイルごと Android の答え方に替える |
| `Http.swift`、`ScanTally.swift` | `URLSession` と、iOS の `URLSession` の癖への対策（401 の要求を 2 回送る、リダイレクト）。`ScanTally` は失敗を `NSURLErrorDomain Code=` の文字列から読む | Android の `URLSession` は libcurl の上の別の実装で、癖もエラーの書き方も違う。テレビの登録（PIN を一度だけ送る）とスキャンの失敗の読み方を、Android の送り方で測り直す。`HTTPTransport` の後ろにあるので、ほかのファイルには響かない |

あわせて、`XMLParser` は `FoundationXML`、`URLSession` は `FoundationNetworking` を import する必要があります
（Apple 以外の Foundation では別のモジュール）。

## 3 つの道

### A. Kotlin で書き直す

- 良いところ: Android のふつうの作り方で、道具が成熟している。テレビのヘルパーと同じ言語になる。
- 困るところ: RecorderKit とモデルの約 25,000 行と、そのテストを書き直す。`docs/port/` の検証ベクタが守るのは、
  コード表、XML の組み立てと解析、EPG、ロゴ、まとめ、重複まで。**接続の規則（`DeviceLink`、2 つのドライバー、送信待ち）は
  ベクタになっていない**ので、iOS で実機と突き合わせて決めた振る舞いを、もう一度実機で確かめ直すことになる。
  そのあとは、振る舞いを直すたびに Swift、Kotlin、Python の 3 か所を直す。

### B. RecorderKit は Swift のまま、画面は Kotlin（Jetpack Compose）で書く

- 良いところ: RecorderKit とそのテストを 1 つのまま持てる。Swift 6.3（2026 年 3 月）から Android 用の Swift SDK が
  正式に出ている。Kotlin から Swift を呼ぶのは swift-java（JNI）。
- 困るところ: アプリのモデル（約 5,700 行）は `@Observable` で画面に変化を伝える作り。Compose との間で変化を渡す層を
  自分で書くことになる。swift-java の JNI モードは 2025 年に足されたもので、Swift の async 関数への対応は
  まだ足されているところ。
  モデルを Kotlin で書けば、その分だけ A と同じ二重持ちが残る。

### C. Skip（Skip Fuse）で、アプリごと Swift のまま Android でビルドする

- 良いところ: Skip Fuse は Android 用の Swift SDK でネイティブにビルドし、SwiftUI を Jetpack Compose に写す。
  モデルも、画面の多くも 1 つのまま持てる見込みがある。Skip は無料のオープンソース（MPL-2.0）。
- 困るところ: 写せない SwiftUI があれば、そこは Android 用に書く。**いちばん心配なのは番組表の表形式**（2 方向の
  スクロール、両方向に残る見出し、ピンチ）。iOS 専用の部品（BackgroundTasks、App Intents、UserNotifications、
  キーチェーン、CryptoKit）は Android 側の実装が要る。iOS のビルドに Skip の仕組みが入るので、Xcode Cloud への
  影響を見る必要がある。

## どの道でも要る Android のこと

- **ローカルネットワークの許可**: Android 17（API 37）を対象にしたアプリは、実行時の許可 `ACCESS_LOCAL_NETWORK`
  が要る。TCP の接続も、UDP のユニキャスト・ブロードキャスト（Wake-on-LAN）も対象。許可がないと TCP はタイムアウト、
  UDP は `EPERM` で失敗する。API 36 以下を対象にしている間は `INTERNET` だけで通るが、Google Play は新しい API レベルを
  対象にするよう求めるので、最初から 37 を対象にして作る。iOS と違い、許可の状態は `checkSelfPermission` で直接読める。
- **平文の HTTP**: Android 9 からは、既定で平文の HTTP を断る（OkHttp や `HttpURLConnection` は network security
  config に従う）。レコーダーもテレビもヘルパーも http なので、設定ファイルで許す。Swift の `URLSession`（libcurl）が
  この設定を見るかどうかは確かめていない。
- **深夜の番組表の更新**: `BGProcessingTask` の代わりに WorkManager（ネットワークを条件にする）。Doze で時刻は
  保証されないので、iOS と同じく手動の更新を残す。
- **テレビの登録の保存**: キーチェーンと AES-GCM の代わりに、Android Keystore の鍵で封じたファイル。
- **通知**: Android 13 からは `POST_NOTIFICATIONS` の実行時の許可が要る。
- **帰宅時に送るショートカットのアクション**（App Intents）: Android に同じものはない。アプリのショートカットか
  クイック設定のタイルで置き換えるか、Android 版では持たないかを決める。
- **配布**: Google Play の個人のデベロッパーアカウントは、製品版の前に 12 人以上で 14 日のクローズドテストが要る
  （テレビのヘルパーの配布で調べたとおり）。

今の Android の利用者には、サーバーを自分で動かして PWA を使う道があります（`porting.md` の冒頭）。

## 1 つのリポジトリでの持ち方

B でも C でも、1 つのリポジトリで持てます。要になるのは iOS にしかないところの差し替え方で、その継ぎ目の多くはもうあります。

置き場所:

- `app/RecorderKit`: 両方のアプリが使う。場所は変えない
- `app/BDBridge`: iOS のアプリ
- `android/`（新しく）: Android のアプリ。`helper/` と同じ Gradle の形で、RecorderKit を Android 向けにビルドした共有ライブラリを取り込む

差し替えは 3 種類です。

1. **部品だけが違うもの**（zlib、SQLite、ソケットの見出し、ログ、ロック）: RecorderKit の中で `#if canImport(...)` で分ける。
   SQLite のソースと zlib のモジュールの定義は、`Package.swift` で Android のときだけ使うターゲットにする
   （`condition: .when(platforms: [.android])`）。分かれ目は数ファイルに集め、ほかのファイルに `#if` を広げない。
2. **振る舞いが違うもの**（HTTP の送り方、ローカルネットワークの許可、Wake-on-LAN の送り方、近くのアドレス）: すでに
   RecorderKit の外から渡す形になっている。`LinkEnvironment` がこれらを関数として受け取り、iOS では `Surroundings` が
   iOS の実装を入れている。Android のアプリは Android の実装を入れる。RecorderKit の規則は変わらない。iOS の許可の
   読み方（`LocalNetworkAccess.swift`）は iOS のときだけビルドする。
3. **アプリの側のもの**（キーチェーン、深夜の処理、通知、ショートカットのアクション）: `app/BDBridge` にあり、iOS だけの
   もの。Android のアプリが自分の実装を持つ。モデル（約 5,700 行）をどこまで共有するかは、B と C の選び方で決まる。

1 つのリポジトリにするために足すもの:

- **Android のビルドが壊れたことに気づく仕組み。** 今 RecorderKit を見ているのは、pre-commit フックの macOS の
  `swift test` と、Xcode Cloud の iOS のビルドだけ。RecorderKit を変えたら Android 向けのビルドも通すよう、フックに
  足す（Mac に SDK があるとき）か、GitHub Actions を足す（今のリポジトリには無い）。
- **ツールチェーンの版。** Android 用の SDK は、同じ版のオープンソースのツールチェーンとしか組めない。Xcode の Swift が
  先に上がったとき、新しい版の機能を RecorderKit で使うと、Android 側は SDK が出るまで待つことになる。
- **iOS アプリの文言の決まり**（アプリとストアの文に Android などの語を入れない）。Android 用のコードと文は
  `#if os(Android)` の中か `android/` に置けば、iOS のバイナリに入らない。共有のコードの文には Android の語を書かない。
- **版とタグ。** iOS（`v*`）、ヘルパー（`helper-v*`）、Android（例えば `android-v*`）を分ける。

## 移植の前に RecorderKit に移すもの

アプリ（`app/BDBridge`）のモデルと画面と iOS の外枠を全部読み（2026-11-04）、Android でもう一度書くことになる規則を
拾いました。2 つに分かれます。

- **RecorderKit に移すもの**: 機器の手順・結果・文なのに、アプリに残っているもの。「機器のことは RecorderKit に」という
  今の決まりからも外れているので、B でも C でも、Android を作らなくても移す価値があります。
- **アプリのモデルを共有のパッケージに出すかどうか**: B と C の選び方で決まります（下の「道の選び方で決まるもの」）。

### RecorderKit に移すもの（Android で書き直す量の多い順）

1. **テレビのヘルパーの番組表**（`AppModelTVGuide.swift` の登録と取得、約 80 行）: 1 時間ごとの確認、遅れている種別の
   判断、取得、失敗の文。レコーダーの同じ仕事は `RecorderGuide.swift` にある。**今テストが 1 件もない**ので、移す先で
   テストを書く。番組表の取得元の選び方はアプリの規則なので残す。
2. **おまかせ・まる録の条件の作り方**（`RecorderRulesScreen.swift`、約 70 行）: キーワード 5 つ・除外ワード 2 つまで、
   「キーワードかジャンルを指定してください」、出すジャンル、放送波と時間帯の選択肢（`Codes` の表を画面で書き写している）、
   既定の 240。PWA にも同じ検査があり、Android で 3 つ目になる。`RecorderConditions.swift` に下書きの型として置く。テストなし。
3. **一括の処理と重複の走査のループ**（`RecorderHostRuns.swift`、446 行）: `RecorderRuns.swift` の上のループ。iOS に
   結びつくのは、アプリを離れても続けるための `UIApplication` の 2 行だけで、これは外から渡す。テストは 70 件ほどあり、
   UIKit の値を見ている 4 件は渡したものを見るように書き換える。
4. **2 つの機器の予約の入口**（`DeviceHost.swift`、161 行）: アプリのモデルに触れるのは、キャッシュを開く 6 か所だけ。
   `ReservationDriver.swift` の横に置く。
5. **テレビの登録の手順**（`TVSettings.swift` と `AppModelTV.swift` の登録）: 探す、PIN なしで登録する、PIN を聞いて
   登録する、の順と、クライアント ID の持ち方。`TVDriver` に置く。
6. **画面で書き写している機器の文**:
   - 番組のシートの「〈機器〉にまだ届いていない予約です。…」は、`PendingQueue` の中の文の写し
   - 予約の削除の確認が 3 か所、送信待ちの削除の確認が 2 か所、接続の状態の言葉が 2 か所に書いてある
   - 重複の削除の文を、`DuplicatesView` が自分で書いている（RecorderKit に同じ文がある）
   - 予約のシートの「登録元」と「番組追従」の言い方
7. **レコーダーの一覧の規則**（`RecorderHost.swift`）: USB HDD の行を残す規則、録画の一覧が USB HDD と合っているかの判断、
   画面下の帯に出す報告の文のつなぎ方。
8. **小さな定数と表**:
   - 放送日の 4 時の区切りを、番組表の表形式が書き写している（`GuideStore` では外から見えない）
   - 放送波の短い名前（番組表の画面にある）を `Codes` に
   - 画質の並びに 2 つの名前がある（`RecorderDriver.recordsIn` と `Codes.qualityOrder`。中身は同じ）
   - おまかせ・まる録の検索方法の言い方が 3 通りある
9. **サンプルの機器の残り**（`DemoData.swift`）: サンプルの機器の組、テレビのアドレス、番組表の範囲、番組表の種まき。
   `DemoRecorder`、`DemoTV`、`DemoLineUp` の横に置く。ロゴのタイルを描くところ（UIKit）は外から渡す。
10. **1 度だけ言ったことの保存**（`DefaultsKey.swift`）: 保存先を外から渡す形にする。

### 移植の前に決めること: 「iPhone」の語

RecorderKit の文のうち 26 行が「iPhone」と書いています（端末のデータベース、送信待ち、接続、探索）。アプリにも 9 行と、
ヘルパーに登録するときの名前「RecBridge (iPhone)」があります。Android で同じ文を出すには、端末の呼び方を 1 か所の
定数か引数にします。iOS の文は変わりません。

### 道の選び方で決まるもの（アプリのモデル）

- 対象: `AppModel`、`RecorderHost`、`TVHost`、予約・録画・番組表の一覧の組み立て、フォアグラウンドとバックグラウンドの
  切り替わり。
- iOS に結びつくところは少ない: 型が 8 か所（`NWPathMonitor`、`UIBackgroundTaskIdentifier`、`UNAuthorizationStatus`、
  `AccessibilityNotification`、`UIApplication`）、通知が 8 か所、`UserDefaults` が数十か所、サンプルのタイルの描画。
  4 つのファイルの `import SwiftUI` は使われていない。
- アプリのテスト 573 件は `Bench.swift` の上で動き、`Bench.swift` は Foundation、RecorderKit、SQLite3、XCTest しか
  使っていない。モデルをパッケージに出せば、多くは `swift test` で走り、Android でも走らせられる。
- 画面の中の状態にも規則がある: 番組のシート（約 260 行）と予約のシート（約 120 行）の状態の移り変わり、空の画面で何を
  言うかの決め方（約 150 行）、検索、局の並べ替え。どれも単体テストがない。
- B（Compose）なら、これらを全部パッケージに出し、Kotlin から変化を見られる形（値の写しと操作）にする必要がある。
  C（Skip）なら画面のまま Android でビルドされるので、出すのは必須ではない。ただし番組のシートと予約のシートは、
  どちらの道でもテストできる形に出す価値がある。

### 移すついでに確かめたいこと（今の iOS の振る舞い）

- 番組のシートから予約を削除するときだけ、おまかせ・まる録で入った予約に「また入ることがある」の文が付かない
  （予約のシートと予約の一覧では付く）。意図したものかどうか。
- 録画の容量は MB を 1024 で割った GB（「GB」の前に空白なし）、残容量はバイトを 10 億で割った GB（空白あり）で、
  単位と書き方が 2 通りある。
- 局の名前の表は数字の放送波コードを、ロゴの表は文字の種別をキーにしている。今は正しいが、取り違えやすい。
- 番組表の日の番号だけが端末の時刻帯の暦を使う（ほかは日本時間）。今は害がない。

## おすすめ

**Swift のまま持っていく（B か C）。Kotlin での書き直し（A）は採らない。** 開発の総量が少なく、以後の変更も
RecorderKit の 1 か所で済むからです。

B と C のどちらにするかは、最初の一歩の結果で決めます。C で番組表の表形式が写せるなら C、写せないなら、
その画面だけ Compose で書くか B にするかを、その時点で比べます。

## 最初の一歩

1. 道具を入れる（ダウンロードなので作者の手で）: swiftly と Swift 6.4.2 のオープンソースのツールチェーン
   （Xcode のツールチェーンでは Android 向けにビルドできない）、Android 用 Swift SDK 6.4.2、NDK r30。
2. RecorderKit を Android 向けにビルドし、上の表のファイルを `#if canImport(...)` で分ける。iOS の動きは変えない
   （macOS の `swift test` がそのまま通ること）。
3. RecorderKit のテストを Android で走らせる。ネットワークを使わないテストなので、エミュレーターで足りる
   （エミュレーターのイメージもダウンロード）。
4. Android の端末から、レコーダーとテレビを Android の送り方で測る（`LiveRecorderTests` の読み取りと、
   `LiveTVTests` の登録）。Android の電話がなければ、BRAVIA（Android 12）で adb から走らせる手もある。
5. C を試すなら、番組表の表形式の 1 画面だけを Skip で Android に出してみる。

## 確かめていないこと

- Android 用の Swift SDK 6.4.2 に `FoundationNetworking`（libcurl）と `FoundationXML`（libxml2）が入っていて、
  実機で動くか。正式版の SDK の作業で両方がビルドできたという報告はあるが、リリースの文書には書かれていない。
- Android の Foundation が `TimeZone(identifier: "Asia/Tokyo")` を端末の時刻帯データから作れるか。
- `Observation` が Android 用の SDK でそのまま使えるか。
- Skip が番組表の表形式を写せるか。

## 出典

- [Swift 6.3 Released](https://www.swift.org/blog/swift-6.3-released/)（Android 用 Swift SDK の最初の正式版）
- [Getting Started with the Swift SDK for Android](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)（6.4.2、NDK r30、swift-java）
- [Put together an Android SDK bundle（swiftlang/swift #80788）](https://github.com/swiftlang/swift/issues/80788)（FoundationNetworking と FoundationXML のビルド）
- [GSoC 2025 Showcase: Extending Swift-Java Interoperability](https://swift.org/blog/gsoc-2025-showcase-swift-java/)（JNI モード）
- [Skip 2026](https://skip.dev/blog/skip-2026/)（Skip Fuse、オープンソース化）
- [Local network permission（Android Developers）](https://developer.android.com/privacy-and-security/local-network-permission)
