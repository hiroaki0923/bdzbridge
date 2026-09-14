# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

bdzbridge: a small LAN bridge for Sony BDZ Blu-ray recorders. It reads the recorder's own 8-day EPG and its UPnP reservation service, and exposes both as a token-protected JSON API plus a mobile PWA, so a phone can browse the guide and schedule recordings (through a VPN such as Tailscale when away from home). Unofficial; talks only to the recorder on the LAN.

- `server/` — Python 3.12+ / FastAPI package `bdzbridge` (uv-managed). Serves `web/dist` at `/` when it exists.
- `web/` — Vite + Svelte 5 PWA (plain JS, runes). Uses `/api/v1` on the same origin; the Vite dev server proxies `/api` to port 8000.
- `docs/` — protocol references: `xsrs-api.md` (reservations), `epg-format.md` (EPG files), `upnp/` (the recorder's UPnP descriptions). Read them before touching recorder code.

Personal/environment notes belong in `CLAUDE.local.md` (gitignored), not here.

## Commands

Server (inside `server/`):

```
uv sync --group dev
uv run pytest -q                       # no recorder needed; the real-file test skips unless BDZBRIDGE_TEST_EPG_FILE is set
uv run pytest -q tests/test_xsrs.py::test_create_elements_match_official_app
uv run ruff check bdzbridge tests
cp .env.example .env                   # set BDZBRIDGE_API_TOKEN; recorder host optional
uv run python -m bdzbridge discover    # list recorders on the LAN
uv run python -m bdzbridge             # serve; OpenAPI at /docs
```

Web (inside `web/`): `npm install`, `npm run build` (writes `web/dist`; restart the server to pick it up), `npm run dev`.

Every API call needs `Authorization: Bearer <BDZBRIDGE_API_TOKEN>`.

## Architecture

- `bdzbridge/recorder/epg.py` — decodes `EPG_*_FILE.dat` (XOR 0x9D, concatenated zlib, "@SRV/@DAY/@EVT" container; see docs/epg-format.md). Has an encoder used only by tests to build fixtures.
- `bdzbridge/recorder/xsrs.py` — SOAP client for `X_ScheduledRecording` / `X_PvrControl`. `build_create_elements` must stay byte-identical to the captured request in `tests/fixtures/create-request.xml`; the recorder answers UPnP error 402 to any deviation (e.g. `+0900` instead of `+09:00`). Updates send the same item with `id` set.
- `bdzbridge/recorder/codes.py` — quality / repeat / broadcasting code tables.
- `bdzbridge/recorder/series.py` — groups recorded titles into programmes by their names (the recorder exposes no series id); `bdzbridge/autorec.py` — keyword auto-reservation run after each EPG refresh, reported through `bdzbridge/notify.py` (SMTP / webhook).
- `bdzbridge/recorder/discovery.py` — SSDP M-SEARCH, then a TCP scan of the local /24 for port 64220; candidates are confirmed via `description.xml`.
- `bdzbridge/recorder/client.py` — one recorder: discovery, EPG download from port 60151, and an `asyncio.Lock` serializing every request (the recorder returns 503 to concurrent requests).
- `bdzbridge/store.py` — SQLite cache of channels/programs with NFKC/case-folded search text. Sub-channel "reference" events resolve to the parent program in SQL. A TV day is 04:00–04:00 JST. `SCHEMA_VERSION` rebuilds the cache on change.
- `bdzbridge/api/app.py` — assembles the FastAPI app: lifespan (creates `Bridge`, starts the refresh loop), the routers under `api/routers/` (recorder, guide, reservations, rules, titles), and the static web app. `api/deps.py` has the bearer-token dependency; `api/serializers.py` turns recorder/store objects into API models.
- `bdzbridge/state.py` — `Bridge`: settings, the selected recorder or None, store, notifier, the cached full title list, and the background jobs (delete / protect / duplicate scan). Recorder selection order: `BDZBRIDGE_RECORDER_HOST` → host saved in SQLite `meta` (re-discovered by UDN if it moved) → unconfigured (only discovery/select and cached EPG work). Tests inject a fake recorder through `create_app(settings, bridge)`; the fakes and the `client` fixture live in `tests/conftest.py`, API tests are split by area (`tests/test_api_*.py`).
- Web: `src/api.js` (fetch wrapper, reservation index), `src/store.svelte.js` (shared state), `src/lib/*.svelte` (Setup, Guide with ProgramList or GuideGrid, Search, Reservations, Titles, Settings, ProgramSheet). The grid view loads a whole TV day with `compact=true`.

## Recorder facts that shape the code

- Creating a reservation with `event_id` makes the recorder follow schedule changes and replaces any title we send with its own EPG title. Time-only reservations never get an event id back-filled.
- The recorder answers in network standby; `X_PowerControl` with `on` works, `PowerOn`/`On` do not.
- Writes to the recorder (create/update/delete) are real. Tests never touch a device; manual checks should use a clearly named reservation and delete it afterwards.
