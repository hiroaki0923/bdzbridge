# recbridge web

Mobile-first PWA for the recbridge API (Vite + Svelte 5, no TypeScript, no UI library).

```
npm install
npm run dev     # http://localhost:5173, /api proxied to the server on 127.0.0.1:8000
npm run build   # -> dist/, served by the server at / when present
```

Screens: token entry → recorder discovery/selection (first run) → 番組表 (broadcasting / TV day / channel → program list),
検索, 予約 (list + delete), 設定 (status, EPG refresh, power, re-select recorder). Tapping a program opens a sheet with
details and either the reservation form (quality, repeat, conflict handling) or, when already reserved, a delete button.
Reserved programs carry a red 予約 mark; the one currently recording shows 録画中.
