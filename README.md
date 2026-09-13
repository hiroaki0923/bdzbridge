# recbridge

Sony 製 Blu-ray レコーダー（BDZ シリーズ）向けの、LAN 内で完結する番組表・録画予約ブリッジです。レコーダー自身が受信した 8 日分の番組表と、レコーダーの UPnP 予約サービスを、トークン付きの JSON API とスマホ向け PWA として提供します。外出先からは Tailscale などの VPN 越しに使う想定で、インターネット上のサービスには依存しません。

Sony 非公式のソフトウェアです。レコーダーが LAN 内に公開している機能を相互運用のために利用しているだけで、映像・音声の保護（DTCP-IP）には触れていません。

## 構成

- `server/` — FastAPI サーバー（`recbridge` パッケージ）。API と PWA の配信、番組表のキャッシュ、レコーダー探索。
- `web/` — Vite + Svelte 5 の PWA。
- `docs/` — レコーダーの予約 API と番組表ファイル形式の仕様（観察に基づく）。

## 使い方

```
cd server
uv sync --group dev
cp .env.example .env        # RECBRIDGE_API_TOKEN を設定
uv run python -m recbridge  # http://127.0.0.1:8000/ （LAN に出すなら RECBRIDGE_BIND_HOST=0.0.0.0）
```

初回はブラウザでトークンを入力し、LAN 内のレコーダーを探索して選びます。選択は保存され、DHCP で IP が変わっても追従します。PWA を更新するときは `web/` で `npm install && npm run build` してサーバーを再起動します。

動作確認機種: BDZ-FBT4100（2020 年モデル）。他の機種は `description.xml` の `EPG_CAP` が `01` であれば番組表も取れる見込みですが未確認です。

## 注意

- レコーダーの API は無認証です。このサーバーを LAN の外に直接公開しないでください。
- 予約の作成・変更・削除は実機に反映されます。
