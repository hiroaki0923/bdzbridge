# recbridge

JSON API in front of a Sony BDZ recorder on the LAN: 8-day EPG (from the recorder itself), reservations with program tracking, recorded titles.

```
uv sync --group dev
cp .env.example .env   # set RECBRIDGE_API_TOKEN; the recorder host is optional
uv run python -m recbridge discover   # optional: list Sony recorders on the LAN
uv run python -m recbridge
```

Then open http://127.0.0.1:8000/docs. All calls need `Authorization: Bearer <token>`.
If `../web/dist` exists (build it with `npm run build` in `web/`), the PWA is served at http://127.0.0.1:8000/.

Recorder selection: if `RECBRIDGE_RECORDER_HOST` is unset, the server starts unconfigured and remembers the recorder you pick
through `GET /api/v1/recorders/discover` + `PUT /api/v1/recorder` (host and UPnP UDN are stored in the SQLite file).
On later starts it reconnects to the saved host, and if the DHCP address changed it re-discovers the same UDN.
Discovery tries SSDP first and falls back to scanning the local /24 for port 64220 (`RECBRIDGE_SCAN_NETWORKS` overrides the CIDRs).

| Method | Path | Purpose |
|---|---|---|
| GET | /api/v1/recorders/discover | Sony recorders found on the LAN |
| PUT | /api/v1/recorder | select a recorder by host (persisted) |
| GET | /api/v1/recorder | configured?, model, power, EPG cache summary |
| POST | /api/v1/recorder/power | wake the recorder |
| GET | /api/v1/defaults | default quality/repeat and label tables |
| POST | /api/v1/epg/refresh | re-download the EPG now |
| GET | /api/v1/channels?broadcasting=td\|bs\|cs\|bs4k | channel list; `logo` is a data: URL of the station logo when the recorder has one |
| GET | /api/v1/programs?broadcasting=&service_id=&date=YYYY-MM-DD&q=&compact= | programs (TV day 04:00–04:00 JST); `compact=true` drops the text fields |
| GET | /api/v1/programs/now?broadcasting=td | now on air |
| GET | /api/v1/programs/{bt}/{service_id}/{event_id} | one program |
| GET | /api/v1/reservations | reservations on the recorder |
| POST | /api/v1/reservations/check | conflict check only |
| POST | /api/v1/reservations | create (409 on conflict unless `force`) |
| PATCH | /api/v1/reservations/{id} | change quality / repeat (time-based ones: also title, start, duration) |
| DELETE | /api/v1/reservations/{id} | delete |
| GET | /api/v1/titles?limit=&offset= | recorded titles (newest first) |
| GET | /api/v1/titles/{id} | program text of one title |
| POST | /api/v1/titles/{id}/play | play it on the TV connected to the recorder (powers the recorder on) |
| GET/POST | /api/v1/recorder/playback | playback status / `{"operation":"pause"|"resume"|"stop"}` |

Reservation body: `{"broadcasting":"td","service_id":1024,"event_id":14792,"quality":"LSR","repeat":"none"}` or, without an event id, `start` + `duration_sec` + `title`.
