# bdzbridge web

Mobile-first PWA for the bdzbridge API (Vite + Svelte 5, no TypeScript, no UI library).

```
npm install
npm run dev     # http://localhost:5173, /api proxied to the server on 127.0.0.1:8000
npm run build   # -> dist/, served by the server at / when present
```

Screens: token entry → recorder discovery/selection (first run) → 番組表 (broadcasting / TV day / channel, as a
program list or a time-by-channel grid), 検索, 予約 (list, edit, delete, plus keyword auto-reservation rules),
録画 (list / programmes / duplicates), 設定 (status, EPG refresh, power, re-select recorder).

Tapping a program opens a sheet with details and either the reservation form (quality, repeat, conflict
handling) or, when already reserved, a delete button. Reserved programs carry a red 予約 mark; the one
currently recording shows 録画中.

The 録画 tab lists what the recorder holds with the free space, genre counts, a sort and a watch-state
filter; gathers recordings into programmes; and finds copies of one broadcast, marking the one to keep.
Deleting or protecting many at once runs as a cancellable job whose progress shows in a bar that outlives
the sheet that started it.
