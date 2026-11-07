# RecBridge ヘルパー（BRAVIA 用）

テレビ（Android TV の BRAVIA）に入れる小さなアプリです。テレビが放送から受け取っている 8 日分の番組表を、同じ家の中の iPhone の RecBridge に HTTP/JSON で配ります。レコーダーのない家でも番組表から録画予約ができるようにするためのもので、予約そのものには関わりません（予約は iPhone がテレビに直接送ります）。

読むのは、チューナーが Android の番組表ストア（`TvProvider`）に書いた局・番組・局ロゴだけです。視聴履歴、おすすめ、録画済みの番組、他のアプリの局は読みません。インターネットには何も送りません。

## 入れ方

ファイルは [Releases](https://github.com/hiroaki0923/bdzbridge/releases) の `helper-v*` にあります（`recbridge-helper.apk` と `SHA256SUMS`）。最新版はいつも同じアドレスです:

```
https://github.com/hiroaki0923/bdzbridge/releases/latest/download/recbridge-helper.apk
```

入れる道は 2 つあります。どちらも、入れたあとの仕上げ（下の「テレビの画面で」）は同じです。

### A. テレビだけで（パソコンなし）

1. テレビの Google Play で「Downloader」（AFTVnews）を入れます。リモコンで URL を打ってファイルを落とし、そのまま入れられるアプリです
2. テレビの設定で、Downloader に「不明なアプリのインストール」を許可します（設定 → アプリ → セキュリティと制限、の中にあります。項目の名前は機種と版で少し違います）
3. Downloader を開き、上のアドレスを入れてダウンロードし、「インストール」を押します
4. 入ったら Downloader の許可は戻してかまいません

USB メモリーに `recbridge-helper.apk` を入れてテレビに挿し、Google Play にあるファイルマネージャーのアプリで開いても同じです。テレビは USB を挿しただけでは何も入れません。

### B. パソコンから（ADB）

Mac か Windows のパソコンが、テレビと同じネットワークにある前提です。

1. パソコンに Android の Platform-Tools を入れます。Google の配布ページから zip を落として展開するだけです（Mac は `brew install --cask android-platform-tools` でも）
2. テレビで開発者向けオプションを出します: 設定 → デバイス設定 → 端末情報 → 「ビルド」を 7 回押す
3. 設定 → デバイス設定 → 開発者向けオプション → 「ネットワークデバッグ」をオン
4. パソコンで `adb connect <テレビの IP アドレス>`。テレビに「USB デバッグを許可しますか」と出るので許可します
5. `adb install -r recbridge-helper.apk`
6. 終わったらネットワークデバッグは切ってかまいません。ヘルパーは ADB なしで動きます

ヘルパーはテレビ本体の保存領域にだけ入ります。テレビが起動したときに自分で立ち上がるためで、USB メモリーや USB HDD（「内部ストレージとして」設定したものも）に入ったアプリには、Android が起動の知らせを届けません。`INSTALL_FAILED_INSUFFICIENT_STORAGE` で失敗するときは、テレビ本体の保存領域が埋まっています（小さく、ほぼ埋まっていることがあります）。使っていないアプリを消して空けてください。

### テレビの画面で

1. ランチャーから「RecBridge ヘルパー」を開きます
2. 「番組表の読み取りを許可する」を押し、許可します。ダイアログが出ないテレビでは、B の道の 4 まで進めてから `adb shell pm grant jp.hiroaki.bdbridge.helper android.permission.READ_TV_LISTINGS` を打ちます
3. 「権限の自動削除を除外」を押し、開いた設定で「アプリの権限を自動的に削除」をオフにします。Android は数か月開かれないアプリの許可を外しますが、ヘルパーは開かれることがほとんどないためです
4. 「登録の番号を出す」で 6 桁の番号を出し、iPhone の RecBridge で 設定 → テレビ → 「ヘルパーに登録」に入れます。番号は 5 分で消えます
5. レコーダーもある家では、RecBridge の 設定 → 「番組表の取得元」で「テレビ」を選ぶと、テレビの番組表になります

### 更新

同じ道で新しい `recbridge-helper.apk` を入れ直します（B は `adb install -r`）。同じ鍵で署名された版なら、許可と登録は残ります。

### 確かめ方

`SHA256SUMS` と照合できます。署名の証明書は、`apksigner verify --print-certs recbridge-helper.apk` で出る SHA-256 が、リリースの説明に書いたものと同じであることを見てください。

## API

ポートは 8780。`GET /ping` と `POST /v1/pair` のほかは `Authorization: Bearer <token>` が要ります。

| 経路 | 内容 |
|---|---|
| `GET /ping` | `{app, api, version}`。トークン不要 |
| `POST /v1/pair` `{code, label}` | 画面の番号でトークンを 1 つ発行。5 回間違えると 10 分受け付けない |
| `GET /v1/info` | 版、許可の状態、チューナーの有無、画面の状態、時計、写しの状態（種別ごとの `etag / snapshotAt / changedAt / programs / channels`）、`tunerLastWrite` |
| `GET /v1/channels` | チューナーの局。`bt, sid, onid, tsid, number, name, serviceType, browsable, hasPrograms, siblings, data`（ETag） |
| `GET /v1/guide/{bt}` | 種別（`td / bs / cs / bs4k / cs4k`）の番組すべて。ETag と `If-None-Match` → 304、gzip |
| `GET /v1/logos/{bt}` | 種別の局ロゴ（PNG、base64）とハッシュ |

番組の行は `sid, eid, startMs, endMs, title, short, long または longTail, genre, canonicalGenre, rating, videoWidth, videoHeight, flag1, flag2, flag4, siblings, siblingEids, data, recordingProhibited`。文字はテレビにあるとおりで、記号の変換や並べ替えはしません（それは iPhone 側の仕事です）。`long` が `short` と空行で始まるときは残りだけを `longTail` に入れます。

種別がテレビに無ければ 404 `{"error":"noSuchType"}`、写しをまだ作れていなければ 503 と `Retry-After`（理由は `noPermission / noTuner / building`）。

写しはテレビの番組表ストアが変わって 10 分静かになったとき（遅くとも 1 時間後）に作り直し、1 世代だけ持ちます。

## ビルド

JDK 17 と Android SDK（platform 34、build-tools 34）があれば `./gradlew assembleDebug` で `app/build/outputs/apk/debug/recbridge-helper-debug.apk`、`./gradlew assembleRelease` で `app/build/outputs/apk/release/recbridge-helper.apk` ができます。依存ライブラリはありません。

release は、署名鍵の設定ファイルがあればそれで署名し、無ければ署名なしで出ます。設定ファイルは `RECBRIDGE_HELPER_KEYS` で指すか、`~/.config/recbridge-helper/key.properties` に置きます:

```
storeFile=recbridge-helper.jks
storePassword=…
keyAlias=helper
keyPassword=…
```

`storeFile` は設定ファイルと同じフォルダーからの相対パスです。鍵はリポジトリに入れません（`.gitignore`）。

## リリース（作者向け）

1. 鍵は一度だけ作り、控えを 2 か所に置きます。失くすと上書き更新ができなくなり、利用者は入れ直しになって許可と登録を失います。証明書の名前は APK に入って誰でも読めるので、アプリの名前だけにします。keytool は JDK 17 以降のものを使います（PKCS12 になり、鍵のパスワードは鍵束のものと同じになります）:

   ```
   mkdir -p ~/.config/recbridge-helper && cd ~/.config/recbridge-helper
   keytool -genkeypair -v -keystore recbridge-helper.jks -alias helper -keyalg RSA -keysize 4096 -validity 36500 -dname "CN=RecBridge Helper"
   ```

2. `app/build.gradle.kts` の `versionCode` を 1 上げ、`versionName` を変えます
3. `./gradlew assembleRelease` → `apksigner verify --print-certs app/build/outputs/apk/release/recbridge-helper.apk` で署名を確かめます
4. `shasum -a 256 recbridge-helper.apk > SHA256SUMS`
5. タグ `helper-v<版>` を打ち、Releases に `recbridge-helper.apk` と `SHA256SUMS` を付け、説明に証明書の SHA-256 を書きます

## 対応

確かめたのは BRAVIA XRJ-65X95K（Android 12）だけです。入れ方 A（Downloader）と、画面の「番組表の読み取りを許可する」のダイアログは、まだこのテレビで確かめていません。
