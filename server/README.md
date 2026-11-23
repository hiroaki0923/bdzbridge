# bdzbridge

JSON API in front of a Sony BDZ recorder on the LAN: 8-day EPG (from the recorder itself), reservations with program tracking, recorded titles. It also reads the disk in the recorder's USB slot (a reservation, a keyword rule or a listing can name `HDD` or `USBHDD`), manages the recorder's own keyword conditions (おまかせ・まる録), wakes the recorder with Wake-on-LAN, and runs bulk delete and protect as cancellable jobs.

This is the server and the API of the bdzbridge project; the app of the same project is called RecBridge (see the [root README](../README.md)).

```
uv sync --group dev
cp .env.example .env   # set BDZBRIDGE_API_TOKEN (without one the server makes a token for each run and prints it); the recorder host is optional
uv run python -m bdzbridge discover   # optional: list Sony recorders on the LAN
uv run python -m bdzbridge
uv run pytest -q                       # no recorder needed
uv run ruff check bdzbridge tests
```

To serve the LAN, set `BDZBRIDGE_BIND_HOST=0.0.0.0` (the default is 127.0.0.1). `.env.example` lists the other settings, among them the port, the database path, the EPG refresh interval, the notification (SMTP or webhook) and the free-space warning.

Then open http://127.0.0.1:8000/docs. All calls need `Authorization: Bearer <token>`.
If `../web/dist` exists (build it with `npm run build` in `web/`), the PWA is served at http://127.0.0.1:8000/.

Recorder selection: if `BDZBRIDGE_RECORDER_HOST` is unset, the server starts unconfigured and remembers the recorder you pick
through `GET /api/v1/recorders/discover` + `PUT /api/v1/recorder` (host and UPnP UDN are stored in the SQLite file).
On later starts it reconnects to the saved host, and if the DHCP address changed it re-discovers the same UDN.
Discovery tries SSDP first and falls back to scanning the local /24 for port 64220 (`BDZBRIDGE_SCAN_NETWORKS` overrides the CIDRs).

The full reference, generated from the app's OpenAPI description, is in [`docs/api.md`](../docs/api.md) (`docs/openapi.json` alongside). A running server serves the same thing interactively at `/docs`. Regenerate after changing routes or models with `uv run python -m bdzbridge.tools.apidoc`; a test fails while the files are stale. `git config core.hooksPath .githooks` (once, in the repository root) installs a pre-commit hook that does this for you, and also regenerates `docs/port/` (`uv run python -m bdzbridge.tools.portkit`, the conformance vectors for a native port; a test fails while they are stale too).

Reservation body: `{"broadcasting":"td","service_id":1024,"event_id":14792,"quality":"LSR","repeat":"none"}` or, without an event id, `start` + `duration_sec` + `title`. Add `"destination":"USBHDD"` to record to the USB disk (the default is `HDD`; 409 when the disk cannot be had), and `"force":true` to create despite overlapping reservations.
