# RecBridge ヘルパー（BRAVIA 用）

テレビ（Android TV の BRAVIA）に入れる小さなアプリです。テレビが放送から受け取っている 8 日分の番組表を、同じ家の中の iPhone の RecBridge に HTTP/JSON で配ります。レコーダーのない家でも番組表から録画予約ができるようにするためのもので、予約そのものには関わりません（予約は iPhone がテレビに直接送ります）。

読むのは、チューナーが Android の番組表ストア（`TvProvider`）に書いた局・番組・局ロゴだけです。視聴履歴、おすすめ、録画済みの番組、他のアプリの局は読みません。インターネットには何も送りません。

## 使い方

1. テレビの「開発者向けオプション」で「ネットワークデバッグ」を有効にし、パソコンから `adb connect <テレビのアドレス>:5555` → `adb install -r recbridge-helper.apk`。
2. テレビのランチャーから「RecBridge ヘルパー」を開き、「番組表の読み取りを許可する」を押して許可する。
3. 「登録の番号を出す」で 6 桁の番号を出し、iPhone の RecBridge の設定でテレビを選んで入力する。番号は 5 分で消える。
4. 終わったらネットワークデバッグは切ってよい（ヘルパーは ADB なしで動く）。

更新は `adb install -r` で、許可と登録は残ります。

テレビ本体の保存領域は小さく、ほぼ埋まっていることがあります。USB メモリーや USB HDD を「内部ストレージとして」設定してあるテレビでは、`adb install -r --install-location 2` でそちらに入ります。X95K では `--install-location 2` を付けない `adb install -r` が本体側に戻してしまったので、更新のたびに付けてください（許可と登録は残ります）。

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

JDK 17 と Android SDK（platform 34、build-tools 34）があれば `./gradlew assembleRelease`。署名鍵はリポジトリに置きません。

## 対応

確かめたのは BRAVIA XRJ-65X95K（Android 12）だけです。
