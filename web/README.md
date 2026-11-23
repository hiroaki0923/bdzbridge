# bdzbridge web

Mobile-first PWA for the bdzbridge API (Vite + Svelte 5, no TypeScript, no UI library). The iOS app of the same project is RecBridge; see the [root README](../README.md).

```
npm install
npm run dev     # http://localhost:5173, /api proxied to the server on 127.0.0.1:8000
npm run build   # -> dist/, served by the server at / when present
npm test        # node --test, no browser needed
```

Screens: token entry → recorder discovery/selection (first run) → 番組表 (broadcasting / TV day / channel, as a
program list or a time-by-channel grid, with a choice and order of stations), 検索, 予約 (list, edit, delete, which disk
it records to, the server's keyword auto-reservation rules, and the recorder's own keyword conditions
おまかせ・まる録, which are created and deleted but never edited), 録画 (list / programmes / duplicates),
設定 (status with the USB disk's free space, EPG refresh, power, re-select recorder).

Tapping a program opens a sheet with details and either the reservation form (quality, repeat, conflict
handling) or, when already reserved, a delete button. Reserved programs carry a red 予約 mark; the one
currently recording shows 録画中.

The 録画 tab lists what both disks hold (the internal HDD and, when one is in the USB slot, the USB HDD, with a
disk filter) with the free space of the disk shown (the internal one unless the filter picks the USB disk), genre
counts, a sort and a watch-state filter; gathers recordings into programmes; and finds copies of one broadcast, marking the one to keep. A title still being written is marked.
Deleting or protecting many at once runs as a cancellable job whose progress shows in a bar that outlives
the sheet that started it.
