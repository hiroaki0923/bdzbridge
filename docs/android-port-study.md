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
- **RecorderKit は Android 向けにビルドでき、テスト 953 件が Android のエミュレーターですべて通りました**（2026-11-05、
  下の「Android でビルドして分かったこと」）。Android の Foundation の違いが 2 つ見つかり、RecorderKit の側で合わせました。
  テレビ用の送り方がリダイレクトについて行くことと、途中で切れた XML を読めたと答えることです。
- アプリの中からも本物のレコーダーを読め、平文の HTTP の設定も要らないことを、エミュレーターで確かめました
  （2026-11-07、下の「アプリの中で確かめたこと」）。まだ確かめていないのは、本物の Wi-Fi の端末から LAN に
  ブロードキャストが出ることと、テレビに話すことです（下の「確かめていないこと」）。

## 規模

| 部分 | 行数 |
|---|---|
| RecorderKit のソース（61 ファイル） | 19,515 |
| RecorderKit のテスト | 36,659 |
| アプリのモデル（`AppModel`、`RecorderHost`、`TVHost`、深夜の処理、保存、通知など） | 約 5,700 |
| アプリの画面（SwiftUI） | 約 6,000 |
| アプリのテスト（`BDBridgeTests`） | 25,205 |

RecorderKit には外部の依存がありません（`Package.swift` は自分のターゲットとテストだけ）。

## RecorderKit の中で Android に合わせたところ

Apple にしかないものは `#if canImport(...)` で分け、Apple の上では元のままにしてあります。

| ファイル | 頼っているもの | Android では |
|---|---|---|
| `Inflate.swift`、`Logo.swift` | `import zlib`（Apple の SDK にあるモジュール） | NDK の zlib を、モジュールマップ `CZlib`（`Sources/CZlib`）から使う |
| `Sqlite.swift` | `import SQLite3`（OS の SQLite） | SQLite のソースを持つターゲット `CSQLite`（`Sources/CSQLite`）。Android は SQLite をアプリに公開していないため（下の「SQLite」） |
| `LocalNetwork.swift`、`WakeOnLan.swift`、`RecorderAddress.swift` | `Darwin` のソケットと `getifaddrs` | `Android` モジュールの同じ関数。`ifa_flags` の定数（Android では enum）、`sa_family` の幅、`sin_len`（Android にない）、`sendto` の引数の型を合わせた |
| `ScanLog.swift`、`WakeOnLan.swift`、`Series.swift` | `os.Logger`、`OSAllocatedUnfairLock` | `AppleShims.swift` に同じ形の型を置いた。ログは Android のシステムのログ（`adb logcat`、タグは `RecorderKit.scan` など）へ書き、公開の印のない値は書かない。鍵は `NSLock` |
| `LocalNetworkAccess.swift` | Network framework の `NWConnection`（iOS のローカルネットワークの許可を、接続の状態から読む） | 作らない。Android の許可は、アプリが Android のやり方で求め、状態を直接読む（下の「ローカルネットワークの許可」） |
| `ScalarClient.swift` | CoreFoundation（JSON の真偽値と数の見分け） | `NSNumber.objCType` で見分ける。Android の `JSONSerialization` は真偽値を `c`、小数を `d` で返す（エミュレーターで確かめた） |
| `Http.swift` | `URLSession` と、Apple の `URLSession` の癖への対策（401 の要求を 2 回送る、リダイレクト） | `FoundationNetworking` を import する。リダイレクトを断るのは、Android ではセッション自身のデリゲート（下で測ったこと） |
| `Xml.swift` | `XMLParser` | `FoundationXML` を import する。途中で切れた文書を拒む確かめを足した（下で測ったこと） |

## Android でビルドして分かったこと

2026-11-05 に、Swift 6.4.2、Android 用 Swift SDK 6.4.2、NDK r30（30.0.16248370）で RecorderKit を arm64 の Android
向けにビルドし、Android 16（API 36）のエミュレーターでテストを走らせました。

- **テスト 953 件がすべて通った**（本物の機器を相手にする 49 件は、Mac と同じく飛ばす）。Mac の 980 件より少ないのは、
  iOS のローカルネットワークの許可を見る 25 件（Network framework）と、サンプルのファイルの SHA-256 を見る 2 件
  （CryptoKit。ファイルが正しいかは OS によらないので Mac で見る）を、Android では作らないためです。
- iOS の動きは変えていません。Mac の `swift test` の 980 件と、iOS アプリのビルドで確かめました。
- **401 の要求は、Android でも一度しか送られない**。テレビの PIN の登録が頼っている振る舞いです。Android の
  `URLSession` は何もしなくても送り直しません。
- **リダイレクト**: 要求ごとに渡すデリゲートは、Android ではリダイレクトについて聞かれません（async の形でも、
  完了ハンドラーの形でも）。そのため、テレビ用のセッション（リダイレクトについて行かない）が、Android では LAN の外の
  宛先にもついて行く作りでした。Android ではセッション自身のデリゲートで断るようにし、テストで確かめました。
- 送れなかったときの文には Android でも `NSURLErrorDomain Code=-1004` が入り、スキャンの数え方（`ScanTally`）は
  そのまま読めました。時間切れと取り消しも同じ番号（-1001、-999）です。
- **Android の `XMLParser`（libxml2）は、途中で切れた文書でも読めたと答えます**（`<a>`、`<a><b></a>`、空の文字列
  など）。宣言されていない接頭辞（`dc:` など）にはエラーを報告しますが、読み取りは続けます。Mac の `XMLParser` は、
  切れた文書には読めなかったと答え、接頭辞には何も言いません。`XmlNode.parse` は、開いた要素がすべて閉じていることも
  確かめるようにしました。Mac での結果は変わりません。
- `Observation`、`Synchronization`、`TimeZone(identifier: "Asia/Tokyo")`（+9 時間）は、そのまま使えました。
- テストの側で変えたこと:
  - 送り方のテストの相手役のサーバーを、Network framework から BSD のソケットに書き直しました。同じテストを
    両方で走らせるためです。
  - 誰も答えない宛先は、Mac では 127.0.0.2、Android では接続を取り出さないソケットです。Linux 系では
    127.0.0.0/8 のすべてが自分自身で、聞いていないポートはすぐに断るためです。
  - 送る順番を待つテストの 2 件は、10 万回の譲りを 1 秒で打ち切ります。エミュレーターでは 10 万回に 13 秒かかり、
    問い合わせが自分の時間切れ（5 秒）で先に出ていました。

## アプリの中で確かめたこと

adb の shell から走らせたテストは、アプリとは違う権限で動き、アプリに効く設定（平文の HTTP など）の外にあります。
そこで 2026-11-07 に、テストをアプリの中で走らせ、Android 16（API 36）のエミュレーターから本物のレコーダーに
話しました。

- **走らせ方**: API 36 を対象にした使い捨ての小さなアプリに、テストの実行ファイルとライブラリを `lib/arm64-v8a/` の
  `lib*.so` として入れ、アプリから子のプロセスとして起こしました。子のプロセスは、アプリと同じユーザーと SELinux の
  ドメイン（`untrusted_app`）で動きます。Android はアプリのデータの場所にあるファイルを実行させないので、
  インストールのときに取り出されるライブラリの場所から起こします。
- **平文の HTTP は、Swift の `URLSession` なら設定なしで通りました。** Java の `HttpURLConnection` は、同じ
  レコーダーへの要求を、既定の設定（平文を断る）のとおり断りました。Android の手引きによると、この設定を守るのは
  Android の HTTP の部品などで、ソケットを直接使うものには効きません。FoundationNetworking（libcurl）も、
  この設定を見ていません。ただ、手引きはほかのライブラリにも守るよう勧めています。Swift の版を上げて
  `URLSession` が守るようになれば、設定が要ります。CI のテストは adb の shell から走るので、この変化には気づきません。
- **本物のレコーダーを読むテスト 6 件が通りました**（`LiveRecorderTests` の読み取りだけのもの）。番組表（地デジと
  BS）の読み取りとキャッシュ、ロゴ、録画一覧のまとめと重複の候補、予約と番組表の突き合わせ、番組表の検索です。
  エミュレーターの通信は、Mac を通って LAN に出ます。
- **アプリの中からブロードキャストを送れました。** Wake-on-LAN の 3 つの宛先（サブネットのブロードキャスト、
  `255.255.255.255`、相手のアドレス）のどれにも、ポート 9 と 7 で、5 秒ごとに送られたものが Mac に届きました。
  宛先の MAC は、どの機器のものでもないものにしました。
- **`getifaddrs` はアプリの中でも使え**、Wi-Fi（`wlan0`）がサブネットを探す先に入りました。ただ、エミュレーターは
  Mac の NAT の内側（10.0.2.0/24）にいるので、探しても LAN のレコーダーは見つかりません（そのとおり 0 件でした）。
- **32 ビットの ARM（armv7）向けのビルドは通りません。** `Int` が 32 ビットになり、サンプルのレコーダーの容量
  （2 TB）の定数があふれます。容量をバイト数の `Int` で持つところは、動かしたときにもあふれます。

## Android 向けのビルドとテストのやり方

道具は、swiftly と Swift 6.4.2（Xcode のツールチェーンでは Android 向けにビルドできない）、Android 用 Swift SDK
6.4.2、NDK r30、エミュレーターとそのイメージです。SDK に NDK をつなぐのは一度だけです。

```
export ANDROID_NDK_HOME=<Android SDK>/ndk/30.0.16248370
~/Library/org.swift.swiftpm/swift-sdks/swift-6.4.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh
```

ビルドと、エミュレーター（または adb につないだ端末）でのテストは、`app/RecorderKit/scripts/android-tests.sh` で
行います。CI（下の「CI」）も同じものを走らせます。

```
export SWIFT="swiftly run swift +6.4.2"
app/RecorderKit/scripts/android-tests.sh build aarch64   # x86_64 のエミュレーターなら x86_64
app/RecorderKit/scripts/android-tests.sh run aarch64
```

- XCTest は共有ライブラリしかないので、テストは Swift の標準ライブラリを静的にリンクしません。スクリプトは、できた
  `RecorderKitTests-test-runner` と `RecorderKitTests.so` を、SDK の Swift の実行時のライブラリ、NDK の
  `libc++_shared.so`、`docs/port` と一緒に端末へ送ります。そして `LD_LIBRARY_PATH`、`TMPDIR`（書ける場所）、
  `RECORDERKIT_VECTORS`（送った `docs/port`）を付けて走らせます。
- 標準ライブラリを静的にリンクする実行ファイル（`--static-swift-stdlib`）は、`FoundationNetworking` の libcurl のために
  `-Xlinker -lssl -Xlinker -lcrypto -Xlinker -lz` が要りました。

### SQLite

Android は SQLite をアプリに公開していません。ふつうの Android アプリは、Java の API（`android.database.sqlite`）を
通してシステムの SQLite を使います。ネイティブのコードは、Android 7.0 から NDK の外のシステムのライブラリに
リンクできません。そのため、ネイティブのコードから SQLite を使うもの（SQLCipher、Google の `androidx.sqlite` の
`sqlite-bundled` など）は、SQLite を自分で同梱しています。

RecorderKit も、SQLite のソース（amalgamation の `sqlite3.c` と `sqlite3.h`、3.54.1）を `Sources/CSQLite` に持ちます。
Android のときだけ使うターゲットなので、iOS のビルドと Mac の `swift test` ではコンパイルされません。Android 向けの
コンパイルは、Apple シリコンの Mac でデバッグが 1.5 秒、最適化ありが 5.3 秒でした。

- 一時ファイルはメモリーに置きます（`SQLITE_TEMP_STORE=2`）。SQLite が一時ファイルの置き場として探す `/var/tmp`、
  `/usr/tmp`、`/tmp` は、Android のアプリには書けないことがあるからです。
- アプリでは、同じデータベースのファイルを Java の API からは開かないこと。同梱した SQLite とシステムの SQLite が
  同じファイルを開くと、ロックが噛み合わず、ファイルが壊れることがあります。
- 版を上げるときは、sqlite.org のダウンロードのページから amalgamation の zip を取り、ページに載っている SHA3-256 と
  一致することを確かめます。そのうえで `sqlite3.c` と `sqlite3.h` を置き換え、`Package.swift` に書いた版を直します。

### CI

`.github/workflows/android.yml` が、PR ごとと main への push ごとに、RecorderKit を x86_64 の Android 向けに
ビルドし、Android 16（API 36）のエミュレーターでテストを走らせます。PR をマージする条件にできるよう、すべての PR で
走ります。RecorderKit、`docs/port`、このワークフローのどれも変えていない PR では、何もせずに通ります。

GitHub の標準のランナーは x86_64 なので、CI のテストは x86_64 のエミュレーターで走ります。arm64 では手元で走らせます。

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
  config に従う）。RecorderKit の Swift の `URLSession` はこの設定を見ないので、RecorderKit の通信には設定が要らない
  （上の「アプリの中で確かめたこと」）。Kotlin の側からレコーダーやテレビやヘルパーに http で話すなら、その宛先を
  設定ファイルで許す。
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

- **Android のビルドが壊れたことに気づく仕組み。** pre-commit フックの macOS の `swift test` と、Xcode Cloud の
  iOS のビルドのほかに、GitHub Actions のワークフローが PR ごとに Android 向けのビルドとテストを走らせる
  （上の「CI」）。
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

1. **テレビのヘルパーの番組表**（済み）: 登録、1 時間ごとの確認、遅れている種別の判断、取得（頼まれたのが取得の
   最中なら、その取得を待って同じことを言う）、画面の行、失敗の文を、`TVHelperGuide.swift` に移した。テストは
   `TVHelperGuideTests` に 10 件。番組表の取得元の選び方と、最後の取得が言ったことを持つのはアプリ
   （`AppModelTVGuide.swift`）。
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

### 端末の呼び方: 「この端末」（決めて、済み）

RecorderKit の文のうち 26 行が「iPhone」と書いていました（端末のデータベース、送信待ち、接続、探索）。iOS の文も
「この端末」に変え、iOS と Android で同じ文を出すことにしました。呼び方を切り替える仕組みは要りません。

アプリの文のうち、データを置く場所やアプリが何かをする端末として「iPhone」と書いていた 6 か所も、同じく
「この端末」にしました。ようこそ画面の紹介の 2 行（「レコーダーの番組表を iPhone で見て」「iPhone をレコーダーや
テレビと同じ Wi-Fi につなぐ」）と、ヘルパーに登録するときの名前「RecBridge (iPhone)」は iOS のアプリのものなので
残しています。Android のアプリは、これらを自分で持ちます。

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

B と C のどちらにするかは、次の一歩の結果で決めます。C で番組表の表形式が写せるなら C、写せないなら、
その画面だけ Compose で書くか B にするかを、その時点で比べます。

## 次の一歩

道具を入れ、RecorderKit を Android 向けにビルドし、テストをエミュレーターで走らせ、アプリの中から本物の
レコーダーを読むところまでは済みました（上の「Android でビルドして分かったこと」と「アプリの中で確かめたこと」）。

1. アプリに残っている機器の規則を RecorderKit に移す（上の「移植の前に RecorderKit に移すもの」）。
2. Wi-Fi の端末で、アプリの中から、ブロードキャストが LAN に出ることと、サブネットを探してレコーダーが
   見つかることを測る。
3. C を試すなら、番組表の表形式の 1 画面だけを Skip で Android に出してみる。

## 確かめていないこと

- 本物の Wi-Fi の端末から、Wake-on-LAN のブロードキャストが LAN に出ること。サブネットを探して、レコーダーが
  見つかること。エミュレーターでは、アプリから送れることと、探す先にサブネットが入ることまで。
- Android の送り方で、テレビに話すこと（`LiveTVTests`）。
- Android 17（API 37）を対象にしたときの、ローカルネットワークの許可の求め方。エミュレーターも試しのアプリも API 36。
- 32 ビットの ARM（armv7）を対象にするか。今はビルドが通らない（上の「アプリの中で確かめたこと」）。
- Skip が番組表の表形式を写せるか。

## 出典

- [Swift 6.3 Released](https://www.swift.org/blog/swift-6.3-released/)（Android 用 Swift SDK の最初の正式版）
- [Getting Started with the Swift SDK for Android](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)（6.4.2、NDK r30、swift-java）
- [SQLite Download Page](https://www.sqlite.org/download.html)（amalgamation と、その SHA3-256）
- [BundledSQLiteDriver](https://developer.android.com/reference/kotlin/androidx/sqlite/driver/bundled/BundledSQLiteDriver)（Google が SQLite を同梱した版）
- [SQLCipher for Android の Android N への対応](https://discuss.zetetic.net/t/sqlcipher-for-android-upcoming-changes-for-android-n-and-coordinated-beta-test-request/1315)（ネイティブのコードからシステムの `libsqlite.so` を使えなくなったこと）
- [Put together an Android SDK bundle（swiftlang/swift #80788）](https://github.com/swiftlang/swift/issues/80788)（FoundationNetworking と FoundationXML のビルド）
- [GSoC 2025 Showcase: Extending Swift-Java Interoperability](https://swift.org/blog/gsoc-2025-showcase-swift-java/)（JNI モード）
- [Skip 2026](https://skip.dev/blog/skip-2026/)（Skip Fuse、オープンソース化）
- [Local network permission（Android Developers）](https://developer.android.com/privacy-and-security/local-network-permission)
- [`android:usesCleartextTraffic`（Android Developers）](https://developer.android.com/guide/topics/manifest/application-element#usesCleartextTraffic)（ソケットから直接送るものには効かないこと）
