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
- 画面はどの道でも Android 用に作ります。ここがいちばん大きい仕事です。
- **道は B に決めました（2026-11-08）。** RecorderKit は Swift のまま、画面は Kotlin（Jetpack Compose）で書きます
  （下の「決めたこと」）。
- **RecorderKit は Android 向けにビルドでき、テスト 953 件が Android のエミュレーターですべて通りました**（2026-11-05、
  下の「Android でビルドして分かったこと」）。Android の Foundation の違いが 2 つ見つかり、RecorderKit の側で合わせました。
  テレビ用の送り方がリダイレクトについて行くことと、途中で切れた XML を読めたと答えることです。
- アプリの中からも本物のレコーダーとテレビを読め、平文の HTTP の設定も要らないことを、エミュレーターで確かめました
  （2026-11-07、下の「アプリの中で確かめたこと」）。本物の Wi-Fi のタブレットでも、サブネットを探してレコーダーと
  テレビが見つかり、Wake-on-LAN のブロードキャストが LAN に出ました（2026-11-08）。まだ確かめていないのは、テレビに
  登録の要る要求を送ることです（下の「確かめていないこと」）。

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
- **アプリの中からテレビにも話せました。** `LiveTVTests/testWhatTheTelevisionSpeaks`（登録の要らない読み取り:
  機種、電源、録画の状態、Wake-on-LAN の MAC があるか、各サービスの版と方法の一覧）が通り、Mac で読んだときと同じ
  答えでした。テレビへの送り方も、平文の HTTP の設定なしで通ります。
- **本物の Wi-Fi のタブレットでも通りました**（2026-11-08、Android 16、arm64）。同じ試しのアプリの中から、アプリの
  「レコーダーとテレビを探す」と同じ探し方（`LiveTVTests/testLookingRoundTheSubnetForBoth`）で、サブネットの 253 の
  アドレスを 5.4 秒で探し、レコーダー 1 台とテレビ 1 台が見つかりました。テレビは指定したアドレスで、機種名も読めました。
  レコーダーの探し方（`LiveRecorderTests/testScanningTheSubnetFindsTheRecorder`）でも見つかりました。その前に送った
  Wake-on-LAN（宛先はどの機器のものでもない MAC）は、ポート 9 と 7 で、サブネットのブロードキャストと
  `255.255.255.255` の両方が Mac に届きました。平文の HTTP の設定は、ここでも要りませんでした。
- **32 ビットの ARM（armv7）は対象にしません**（2026-11-07 に決めました）。ビルドも通りません。`Int` が 32 ビットに
  なり、サンプルのレコーダーの容量（2 TB）の定数があふれ、容量をバイト数の `Int` で持つところは動かしたときにも
  あふれます。

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
- **テレビの登録の保存**（済み）: アプリのフォルダーのうち、バックアップにも別の端末への引き継ぎにも含まれない
  `getNoBackupFilesDir()` に、ファイルとして置く。Android のバックアップの規則は、このフォルダーをいつも外す。
  アプリの内部ストレージのファイルはそのアプリだけが読め、Android の説明書は、たいていのアプリにはそれで足りると
  している。iOS がキーチェーンの項目を鍵のファイルで封じているのは、項目がアプリを消したあとも残りうるためで、
  Android ではアプリを消すとフォルダーごと消えるので、その理由がない。ここは当初、Android Keystore の鍵で封じた
  ファイルにするつもりだった。
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
2. **おまかせ・まる録の条件の作り方**（済み）: キーワード 5 つ・除外ワード 2 つまで、「キーワードかジャンルを指定して
   ください」、出すジャンル、ジャンルを変えるとサブジャンルを外すこと、放送と時間帯の選択肢（画面が `Codes` の表を
   書き写していた）、既定の 240 を、`RecorderConditions.swift` の下書きの型 `RecorderRuleDraft` に移した。テストは
   `RecorderRuleDraftTests` に 8 件。画面の説明の文は画面に残した。PWA にも同じ検査があり、そちらはそのまま。
3. **一括の処理と重複の走査のループ**（済み）: ループとジョブ、中止、アプリが裏にいるあいだの待ち、1 件ごとの結果の
   持ち方、重複の走査を、`BulkRuns.swift` に移した。アプリが渡すのは、裏にいるかどうか、1 歩を続けるための
   バックグラウンドタスク（`UIApplication`）、終わったあとの再接続とテレビの一覧の読み直し。いつ始めてよいかは
   アプリの規則として `RecorderHostRuns.swift` に残した。ループのテストは `BulkRunsTests` に 6 件。アプリのテスト
   （`RunGateTests` など）はモデルを通して確かめるので、アプリに残した。
4. **2 つの機器の予約の入口**（済み）: 6 つの入口と古い表示の判断（`staleSince`）を、RecorderKit の
   `DeviceHost.swift` に移した。アプリのモデルに触れていたキャッシュを開くところは、各ホストが答える `openCache` に
   した。テストは `DeviceHostTests` に 8 件。
5. **テレビの登録の手順**（済み）: アドレスに何があるかを聞き、電源の入ったテレビにだけ PIN なしで登録し、PIN を
   聞いて登録する、という押すたびの手順（閉じたフォームのためには登録しないことも）と、クライアント ID の決め方を、
   `TVRegistration.swift`（`TVDriver.register`、`TVDriver.clientID`）に移した。テストは `TVRegistrationTests` に 6 件。
   登録が通ったあとに保存し、リンクを作り直してつなぐのはアプリ（`AppModel.registerTV`）。
6. **画面で書き写している機器の文**（済み）: 番組のシートの「〈機器〉にまだ届いていない予約です。…」
   （`PendingQueue.notYetAt`）、予約の削除の確認 3 か所と送信待ちの削除の確認 2 か所
   （`Reservation.whatDeletingDoes`、`PendingReservation.whatDeletingDoes`）、接続の状態の言葉 2 か所
   （`SessionState.standing`）、重複の削除の文（RecorderKit にあった `deletedForGood`）、予約のシートの「登録元」と
   「番組追従」の言い方（`Reservation.madeBy`、`followsItsProgramme`）を、RecorderKit の文から言うようにした。
   テストは `ReservationSentencesTests` に 4 件。
7. **レコーダーの一覧の規則**（済み）: USB HDD の行を残す規則（`keeping(_:readFrom:usb:)`）、録画の一覧が USB HDD と
   合っているかの判断（`isOutdated(readFrom:usb:)`）、画面下の帯に出す報告の文のつなぎ方（`StripReport`）を、
   RecorderKit の `StripReport.swift` に移した。テストは `StripReportTests` に 5 件。いつ判断するか（一覧を読めたか、
   一括の処理の最中か、USB HDD がまだ答えていないか）はアプリ。
8. **小さな定数と表**（済み）: 放送日の 4 時の区切りを `GuideStore.dayStartHour` と `minuteOfTheBroadcastDay` に
   して番組表の表形式から使い、放送波の短い名前を `Codes.broadcastingShortLabel` に移し、画質の並びの名前を
   `RecorderDriver.recordsIn` の 1 つにした（`Codes.qualityOrder` はなくした）。おまかせ・まる録の条件の行の組み立ては
   `RecorderRule.details` に移した。検索方法の言い方が 3 通りあるのは、最後の文言の確認でまとめる（`Codes` の表は
   サーバーと同じ語で、`docs/port` で突き合わせている）。テストは `SmallTablesTests` に 4 件。
9. **サンプルの機器の残り**（済み）: サンプルの機器の組（`DemoDevices`）、テレビのアドレス（`DemoTV.host`）、
   応答の速さ（`DemoRecorder.answerDelay`）、番組表の範囲の文（`DemoLineUp.guideCoverage`）、番組表の種まき
   （`DemoLineUp.seed`）を、RecorderKit の `DemoDevices.swift` に移した。ロゴのタイルの描画（UIKit）はアプリから渡す。
   デモの切り替えは設定の保存に結びつくので、アプリ（`DemoData.swift`）に残した。テストは `DemoDevicesTests` に 2 件。
10. **1 度だけ言ったことの保存**（済み）: 画面のない処理が 1 度だけ言ったこと（`ToldOnce`）の読み書きと、そのキーを、
    RecorderKit の `KeptOnce.swift` に移した。保存先はプロトコル（`KeptData`）で、iOS のアプリは `UserDefaults` で
    答える（`DefaultsData`）。テストは `KeptOnceTests` に 3 件。

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
- B に決めたので、これらを全部パッケージに出し、Kotlin から変化を見られる形（値の写しと操作）にする。
  番組のシートと予約のシートの状態の移り変わりも出し、テストを書く。

### 移すついでに確かめたいこと（今の iOS の振る舞い）

- 番組のシートから予約を削除するときだけ、おまかせ・まる録で入った予約に「また入ることがある」の文が付かなかった
  （予約のシートと予約の一覧では付く）。3 か所とも付けることにし（2026-11-07）、番組のシートは予約のシートと同じ文を
  言う。一覧とシートで言い方が 2 通りあるのは、最後の文言の確認でまとめる。
- 録画の容量は MB を 1024 で割った GB（「GB」の前に空白なし）、残容量はバイトを 10 億で割った GB（空白あり）で、
  単位と書き方が 2 通りある。
- 局の名前の表は数字の放送波コードを、ロゴの表は文字の種別をキーにしている。今は正しいが、取り違えやすい。
- 番組表の日の番号だけが端末の時刻帯の暦を使う（ほかは日本時間）。今は害がない。

## Skip で番組表の表形式を写した試し（2026-11-08）

C を選ぶかを決めるため、iOS の番組表の表形式（`GuideGridView`）を、作りを変えずに Skip Fuse の小さなアプリに
写し、Android のタブレットで動かしました。RecorderKit とアプリ固有の部品は最小の代わりに差し替え、番組は作りものです。

- **描くことはできました。** 局の列、時刻の目盛り、番組の枠、ジャンルの色、予約の色は出ました。
- **作りの芯が働きませんでした。** 番組表は、スクロールの中に置いた `GeometryReader` で中身のずれを読み、時刻と局名の
  見出しを動かし、見えている範囲だけを描いています。Android では、スクロールしてもこの位置が知らされず、見出しが
  ついてこず、描く範囲も古いままで空白ができました。スクロールの位置を読む別の書き方（`scrollPosition`）は、
  Skip のソースでは中身のない形だけのもので、`onScrollGeometryChange` はありませんでした。開いたときに今の時刻へ
  移る `scrollTo` も効きませんでした。
- **Android 側にない書き方が 6 種類ありました。** `@State private var`（internal にしないと使えない）、`Text + Text`、
  `coordinateSpace`、`contentShape`、SF Symbols の `minus`、文字列をそのまま渡す `accessibilityLabel`。ほかに、
  長い修飾の連なりは、分けないと Android 向けのコンパイルで型が決まりませんでした。
- Android の部分だけを Compose で書いて埋め込む仕組み（`ComposeView`）はあります。

## swift-java の試し（2026-11-08）

B のいちばんの不確かさだった「Kotlin から RecorderKit を呼べるか」を、使い捨ての小さなアプリで確かめました。
swift-java 0.7.0 の JNI 方式で、Swift の小さなパッケージ（RecorderKit を使う）から Java の呼び口を自動で作り、
Kotlin の Activity から呼んで、Android 16 のエミュレーターで動かしました。組み立ては swift-android-examples の
`swift-java-weather-app` と同じです。

| 確かめたこと | 結果 |
|---|---|
| ふつうの関数 | `String` で返る。日本語もそのまま |
| async の関数 | `CompletableFuture` で返る。完了するのは Swift の並行処理のスレッドで、UI のスレッドではない |
| throws の関数 | `CompletionException` の中に、Swift のエラーの型名つきの Java の例外として届く |
| 構造体 | Java のクラスになり、getter で読める。受け取るときは寿命を持つ `SwiftArena` を渡す |
| 一覧 | `[String]` は `String[]`、構造体の一覧は構造体のクラスの配列で受け取れる |
| Swift から Kotlin へ知らせる | Kotlin で実装した protocol（`enableJavaCallbacks`）を、Swift の Task から呼べる。届くのは Swift のスレッド |

RecorderKit の中身（レコーダーの説明、テレビの在否、サブネットの探索）も、Kotlin まで届きました。

組み立てで要ったこと:

- swift-java の Java の支え（SwiftKitCore）は Maven Central になく、swift-java のチェックアウトから
  `publishToMavenLocal` で手元に置く。既定は JDK 25 を求めるが、`-PswiftJavaJdk=21` で JDK 21 でもビルドでき、
  出来上がりは Java 11 向け。Homebrew の JDK は `JAVA_HOME` を `…/libexec/openjdk.jdk/Contents/Home` にする
  （そうしないと版を読めず 25 を探しに行く）。
- `enableJavaCallbacks` を使うと、Swift のビルドの途中で swift-java が Gradle を動かすので、`swift build` にも
  `JAVA_HOME`（17 以上）が要る。サンドボックスも外す（`--disable-sandbox`）。
- APK に詰めるのは、ビルドした `.so`（RecorderKit は中に静的に入る）、`libc++_shared.so`、Swift の実行時の
  ライブラリ（Foundation、FoundationNetworking、FoundationXML、Observation などを含む 19 個）。デバッグ版で
  arm64 だけの APK は 143 MB だった。

分かった約束事: Kotlin で受け取った結果と知らせは Swift のスレッドで届くので、画面の状態に入れる前に UI の
スレッドに渡す。

その後、`android/` にアプリの最初の形を作りました（`android/README.md`）。リリース版は、R8 で縮め、Swift を
最適化してビルドし、ライブラリの記号を落として 76 MB になり、エミュレーターで動きました。R8 には、Swift の側が
名前で呼ぶ swift-java のクラスを残す指定と、SwiftKitCore が名前だけ使う `jdk.jfr` の注釈を見逃す指定が要りました。
76 MB のうち 38 MB は、Foundation が日付と文字の扱いに使う ICU のデータです（RecorderKit は日本語の日付を
`DateFormatter` で書くため要る）。

**Android では、そのままでは Swift の main actor が動きません。** Swift のメインのキューを回すものがないため、
`@MainActor` の処理は始まらず、待つものは永遠に待ちます（エミュレーターで 8 秒待っても返らなかった）。
RecorderKit の多くとアプリのモデルは `@MainActor` なので、B ではここが要になります。

Foundation の RunLoop は、メインのスレッドで回ると、メインのキューも回します（iPhone で UIKit の下で回るのと
同じ）。Android のメインのスレッドは Android の Looper のものなので、RunLoop に回させ続けることはできません。
そこで、画面が出ている間、アプリのメインのスレッドから 1 フレームに 1 回ほど RunLoop を一度だけ回し、それまでに
来た処理を済ませてすぐ戻るようにしました（`android/core/Sources/AndroidBridge/MainQueue.swift` と
`MainActivity`）。エミュレーターで確かめたことは次の 2 つです。

- これを止めると、デモの番組表が 30 秒たっても出ず、画面のテストが落ちる。
- 画面を出したまま何もしないときの CPU は、止めたときの 0〜0.6% に対して 0.8〜1.4%。画面が裏に回ると止まる。

呼ぶのは公開の関数だけです。処理が来たときにちょうど起こす方法は、どちらも Swift 6.4.2 では公開されていません。

- メインのキューのファイル記述子を Looper に登録する方法は、libdispatch の非公開の関数を使う。
- main actor の実行役をアプリが差し替える仕組み（`MainExecutor`、`ExecutorFactory`）は、
  `@_spi(ExperimentalCustomExecutors)` の中にある。

### モデルの変化を Kotlin に知らせる試し（2026-11-08）

手順 2（下）の形を決めるため、iOS のモデルと同じ `@MainActor @Observable` のクラスを、使い捨てのアプリで Kotlin から
見ました。swift-java 0.7.0、エミュレーター。

| 確かめたこと | 結果 |
|---|---|
| `@MainActor @Observable` のクラスをそのまま出す | コンパイルできない。swift-java は同期の呼び口を作り、main actor の外から呼ぶことになる。async の関数だけは通る |
| 前に main actor でない窓口を置く（操作は async で main actor に渡る） | 動く。`Observations` でも `withObservationTracking` でも、変化 1 回につき 1 回、Kotlin の listener に届いた。届くのは Android のメインスレッド |
| listener の引数 | 数（`Int64`）、文字、真偽値は届く。`Int` は swift-java の作るコードがコンパイルできない。構造体の一覧は、アプリのクラスを探せず落ちた（`NoClassDefFoundError`） |
| Foundation の `UserDefaults` | `.standard` と名前で指定したものは、値が残らなかった（HOME と XDG をアプリのフォルダーに向け、フォルダーを作っても同じ。アプリの bundle identifier が取れない）。置き場所をファイルの場所（絶対パス）で指定した `UserDefaults(suiteName:)` は、次の起動でも値が読めた。ただし、ファイルに書くのは `synchronize()` を呼んだときだけで、値を変えても変化の知らせ（`didChangeNotification`）は出ない（手順 3 で窓口を作るときに分かった）。Application Support の場所は、XDG を向ければ取れる |

分かった形: モデルは iOS のまま `@MainActor @Observable` にし、前に画面ごとの窓口を置く。窓口は「何が変わったか」だけを
知らせ、値は Kotlin が async で読む（Kotlin から呼んだ結果なら、構造体の一覧も届く）。設定は、モデルが今も
`Surroundings` から受け取る `UserDefaults` のままでよく、Android はファイルの場所で指定したものを渡す。Apple の
Foundation は自分で書き出すので、モデルは `synchronize()` を呼ばない。Android が渡すものは、値が変わるたびに
自分で書き出す（`WrittenDefaults`、`android/core/Sources/AndroidBridge/App.swift`）。

## 決めたこと: B（2026-11-08）

**RecorderKit は Swift のまま Android 向けにビルドし、画面は Kotlin（Jetpack Compose）で書きます。** Kotlin での
書き直し（A）も、Skip（C）も採りません。リポジトリの持ち主が決めました。理由は次の 3 つです。

- Android のアプリは Android らしい見た目と操作にしたい。
- B のほうが試行錯誤が少なくて済む（試しでは、番組表の 1 画面で Android 側にない書き方に 6 種類当たった）。
- 開発の総量はコード量だけではない。あとの手入れで Skip が行き詰まりの元になるのは避けたい。

## 次の一歩

道具を入れ、RecorderKit を Android 向けにビルドし、テストをエミュレーターで走らせ、アプリの中から本物の
レコーダーを読むところまでは済みました（上の「Android でビルドして分かったこと」と「アプリの中で確かめたこと」）。
アプリに残っていた機器の規則も、RecorderKit に移しました（上の「移植の前に RecorderKit に移すもの」の 1〜10）。

Wi-Fi の端末での測定と、Skip の試しも済みました（上）。B での次の一歩は次の順です。

1. ~~Kotlin から swift-java で RecorderKit を呼ぶ試し~~（済み、上の「swift-java の試し」）。
2. アプリのモデル（`AppModel`、`RecorderHost`、`TVHost`、一覧の組み立て、シートの状態の移り変わり）を、UI のない
   パッケージに出し、Kotlin から値の写しと操作で見られる形にする。iOS もこれを使う。
   - モデルを iOS から切り離し（#121）、RecorderKit の 2 つ目のターゲット `RecBridgeModel` に移しました。モデルは
     `@MainActor @Observable` のまま、`public` はアプリが使う名前だけです。
   - アプリのテスト 574 件のうち 555 件は、モデルと一緒にパッケージに移りました（`RecBridgeModelTests`）。
     シミュレーターなしの `swift test` で、Mac でも Android のエミュレーターでも走ります。アプリに残ったのは、
     アプリそのものが要る 19 件です（Keychain、番組表の表形式、アプリの起動など）。
   - Android で走らせて、モデルの順番の取り違えが 1 つ見つかりました。一覧の読み直しの後ろに保護の要求が
     並んでいるとき、読み直しの答えが保護の答えのあとでモデルに入ると、保護の印が古い一覧で消えます（削除なら、
     消した録画が一覧に戻ります）。Android のエミュレーターでは毎回そうなり、iPhone と Mac ではそうなって
     いませんでした。レコーダーは要求を 1 つずつ答えますが、どちらの答えを先にモデルに入れるかは、それでは
     決まらないためです。そこで、録画への書き込み（保護、削除）は、出ている一覧の読み直しが一覧を入れ終える
     まで待ってから送るようにしました。まとめての処理も、録画を一覧で引く前に待ちます。iOS でこれまで起きて
     いた順番が、どこでも必ずそうなります。
   - シートと画面の規則も、テスト付きでモデルに移しました。番組のシートと予約のシートの状態の移り変わり
     （`ProgramSheetState`、`ReservationSheetState`）、検索（`SearchState`）、局の並べ替え（`ChannelsState`）、
     空の画面で何を言うか（`AppModelEmptyScreens.swift`）です。SwiftUI の画面はそれを並べて結ぶだけになり、
     Android の画面も同じ型を使えます。
3. 画面を Compose で書く。
   - 3 の入口として、読むだけのアプリの骨組みを先に作りました（`android/README.md`）。エミュレーターから本物の
     レコーダーも読めました。
   - その骨組みを、iOS と同じモデルの上に載せ替えました。Android のアプリは、iOS のアプリと同じように
     `AppModel` を 1 つ持ち、画面ごとの窓口（`android/core/Sources/AndroidBridge`）を通して見ます。窓口は
     `Observations` でモデルを見て、変わったことだけを Kotlin に知らせます。Kotlin はそのたびに、iOS の画面と同じ
     言葉にした値を読みます。モデルには手を入れていません。今あるのは、つなぐ画面（探索、アドレス、デモ）、
     番組表（放送と局と日の選択、今、番組表の更新、空のときの文）、予約と録画の一覧（読むだけ）です。
     デモを画面からたどるテストが 4 件、窓口のテストが Mac で 6 件あります。
   - 画面は Material 3 の作法に寄せました（Android らしい見た目と操作に、という持ち主の考えのとおり）。電話では
     下のナビゲーションバー、幅の広い端末では左のナビゲーションレール、画面ごとの上のバーと、その下の帯
     （iOS の画面の上の帯と同じもの）です。
   - 番組のシートと予約のシートを、モデルの `ProgramSheetState` と `ReservationSheetState` の上に置き、
     予約の書き込み（予約する、変更する、削除する、送信待ちを送り直す・削除する）を入れました。iOS のシートが
     `onChange` と `task(id:)` で受け持つこと（レコーダーが替わったら問いを下げる、時間の重なりを聞き直す
     など）は、シートの窓口が受け持ちます。書き込みはデモのレコーダーで確かめました。
   - 録画のシートの規則も、番組のシートと予約のシートと同じく、モデルに移しました（`TitleSheetState`、テスト付き。
     iOS の画面はそれを並べるだけです）。Android の録画の画面には、絞り込みと並び順のメニューと、録画のシート
     （再生・一時停止・停止・電源、保護、削除）を置きました。まとめ表示、重複、一括の削除と保護、一覧のスワイプは
     まだです。
   - 設定の画面のうち、レコーダーの部分の規則（アドレスと MAC の欄が何に従うか、「このアドレスに接続」と「再接続」を
     いつ出していつ止めるか）をモデルに移しました（`RecorderSettingsState`、テスト付き。iOS の画面はそれを並べるだけ
     です）。「ご利用上の注意」の文もモデルに置きました。Android には設定の画面（レコーダー、既定の録画モード、探索、
     保存されている番組表、デモ、ご利用上の注意、バージョン）と、局の表示と並び順の画面（並べ替えはドラッグ）を
     置きました。iOS だけの通知とショートカットは持ちません。
   - テレビの登録のシート、ヘルパーの登録のシート、設定のテレビの部分の規則を、モデルに移しました
     （`TVRegisterState`、`HelperRegisterState`、`TVSettingsState`、テスト付き。iOS の画面はそれを並べるだけです）。
     Android には、設定のテレビの部分（機種・状態・USB ハードディスク、対応状況を調べる、登録する・再接続、
     ヘルパー、テレビを外す）、探して見つかったテレビ、番組表の取得元、帯の「登録」、テレビの録画の一覧を待つことを
     置きました。テレビの登録は、バックアップにも引き継ぎにも含まれないフォルダーに置きます（上の「テレビの登録の
     保存」）。
   - Android に検索の画面を置きました。規則は、すでにモデルにある `SearchState` のものです。iOS の画面が
     `task(id:)` で受け持つこと（語か対象が変わったら少し待って番組表を検索し直す、対象を変えたら一覧を読む）は、
     画面が出ている間、窓口が受け持ちます。検索の対象（番組表・予約・録画）は、検索欄の下にいつも出しています。
     見つかった番組と予約の行には、日付も出します（iOS の行は時刻だけです）。何も見つからなかったときの文は、
     iOS ではシステムの文なので、Android の窓口に置きました。

## 確かめていないこと

- Android の送り方で、テレビに登録の要る要求を送ること（cookie を付けた読み取りと書き込み）。
- Android 17（API 37）を対象にしたときの、ローカルネットワークの許可の求め方。エミュレーターも試しのアプリも API 36。
- `SwiftArena.ofAuto()` に任せた構造体の寿命が、長く動くアプリでどう振る舞うか。

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
