# App Store 用スクリーンショットの撮り方

**実在の放送局・番組・録画が写らないよう、架空のデータで撮る。** レコーダーも実機も要らない。
番組表以外の画面（予約一覧・録画一覧・おまかせ・設定）に出るのは、そのまま「誰が何を見て
いるか」「どこに住んでいるか」「何を契約しているか」なので、店先に出すものではない。

中身は `app/BDBridge/DemoData.swift`。偽レコーダー（`DemoTransport`）と偽番組表からできて
いて、局名・番組名・録画タイトル・キーワード・IP・MAC はすべて架空。**`#if DEBUG` なので
ストアに出すビルドには入らない。**

モックではない点がひとつある: 返している XML は BDZ-FBT4100 が実際に返す形で、それを本物と
同じパーサが読む。画面に出ているのは「架空のデータで動いているアプリ」そのものである。

## 撮る

```bash
# UDID の確認
xcrun simctl list devices available

app/scripts/screenshots/capture.sh <デバイスUDID> [ラベル]
```

出力先は `~/Pictures/BDBridge-AppStore/<ラベル>/`。`BDBRIDGE_SHOT_OUT` で変えられる。

**寸法は App Store Connect の指示に従うこと。** 寸法はシミュレータの機種で決まるので、
要求された寸法の機種を作って使う。

| 要求寸法 | 機種 |
|---|---|
| 1284×2778 | iPhone 14 Plus / 13 Pro Max / 12 Pro Max |
| 1242×2688 | iPhone 11 Pro Max / Xs Max |
| 1320×2868 | iPhone 17 Pro Max / 16 Pro Max |

古い機種は既定では用意されていないので、作る:

```bash
xcrun simctl create "iPhone 14 Plus (AppStore)" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-14-Plus \
    com.apple.CoreSimulator.SimRuntime.iOS-26-0
```

## 仕組み

画面遷移は `app/BDBridgeUITests/ScreenshotTests.swift`（XCUITest）が行う。`capture.sh` が
`BDBRIDGE_SHOTS` を渡し（`xcodebuild` は `TEST_RUNNER_` の接頭辞を外してテストランナーに
渡すので、両方の名前で渡している）、環境変数が無いときテストは skip する。普段の全件テスト
には影響しない。

撮った画像は xcresult の添付として出てくるので、`capture.sh` が取り出して名前を付け替える。

画面の指定は起動引数で行う。`-demoData 1` のほか、アプリが元から持っている
`-startTab` / `-guideMode` / `-recordingsMode` を使うので、タブやモードを探してタップする
必要がない（引数のドメインは保存された設定より優先される）。

## 撮影時のはまりどころ

- **夕方から夜に撮ると番組表の絵が良い。** 表形式は現在時刻の位置を開くので、撮った時刻の
  番組が写る。深夜に撮ると深夜の番組が並ぶ。ステータスバーの時計も撮影時刻に合わせている
  （9:41 に固定すると、番組表の赤い現在時刻線と食い違って見える）
- **番組の詳細は検索から開く。** 番組表から開くと、いま何時かによって画面に出ている番組が
  変わってしまう。検索なら番組名で確実にたどれる
- **リストの行は要素の種類を決め打ちしない。** SwiftUI の行は button だったり staticText
  だったりする。`staticTexts.matching(labelContains(...))` を通してタップしている
- **重複の確認を待ってから撮る。** 番組シートはレコーダーに重複を問い合わせるので、
  「重複する予約はありません」が出るのを待たないと空の行が写る
- 画面が出た直後は List のアニメーションが途中なので、1 秒ほど置いてから撮っている
