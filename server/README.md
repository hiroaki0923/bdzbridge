# bdzbridge

JSON API in front of a Sony BDZ recorder on the LAN: 8-day EPG (from the recorder itself), reservations with program tracking, recorded titles.

```
uv sync --group dev
cp .env.example .env   # set BDZBRIDGE_API_TOKEN; the recorder host is optional
uv run python -m bdzbridge discover   # optional: list Sony recorders on the LAN
uv run python -m bdzbridge
```

Then open http://127.0.0.1:8000/docs. All calls need `Authorization: Bearer <token>`.
If `../web/dist` exists (build it with `npm run build` in `web/`), the PWA is served at http://127.0.0.1:8000/.

Recorder selection: if `BDZBRIDGE_RECORDER_HOST` is unset, the server starts unconfigured and remembers the recorder you pick
through `GET /api/v1/recorders/discover` + `PUT /api/v1/recorder` (host and UPnP UDN are stored in the SQLite file).
On later starts it reconnects to the saved host, and if the DHCP address changed it re-discovers the same UDN.
Discovery tries SSDP first and falls back to scanning the local /24 for port 64220 (`BDZBRIDGE_SCAN_NETWORKS` overrides the CIDRs).

The full reference, generated from the app's OpenAPI description, is in [`docs/api.md`](../docs/api.md) (`docs/openapi.json` alongside). A running server serves the same thing interactively at `/docs`. Regenerate after changing routes or models with `uv run python -m bdzbridge.tools.apidoc`; a test fails while the files are stale.

Reservation body: `{"broadcasting":"td","service_id":1024,"event_id":14792,"quality":"LSR","repeat":"none"}` or, without an event id, `start` + `duration_sec` + `title`.
