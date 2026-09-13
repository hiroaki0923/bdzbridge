from __future__ import annotations

import asyncio
import base64
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path

import httpx
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.staticfiles import StaticFiles

from ..config import Settings
from ..recorder import codes, discovery
from ..recorder.client import RecorderClient
from ..recorder.epg import JST
from ..recorder.xsrs import RecordedTitle as XTitle
from ..recorder.xsrs import Reservation as XReservation
from ..recorder.xsrs import XsrsError, build_create_elements, build_update_elements
from ..store import ProgramRow, Store
from . import schemas as S

log = logging.getLogger("recbridge")
bearer = HTTPBearer(auto_error=False)


def _genres(pairs) -> list[S.Genre]:
    return [S.Genre(level1=a, level2=b, label=codes.GENRE_LABEL.get(a, "不明")) for a, b in pairs]


def _genres_from_code(code: int | None) -> list[S.Genre]:
    """The recorder's genreID is the first ARIB content descriptor pair packed as level1 * 16 + level2."""
    return _genres([(code >> 4, code & 0xF)]) if code is not None else []


def program_out(p: ProgramRow, compact: bool = False) -> S.Program:
    return S.Program(broadcasting=p.bt, service_id=p.service_id, service_name=p.service_name, event_id=p.event_id,
                     start=p.start, end=p.end, duration_sec=int((p.end - p.start).total_seconds()), title=p.title,
                     description="" if compact else p.description, extended="" if compact else p.extended,
                     genres=_genres(p.genres),
                     copy_control=p.copy_control, parental_rating=p.parental, is_reference=p.is_reference,
                     ref_service_id=p.ref_service_id, ref_event_id=p.ref_event_id)


def reservation_out(r: XReservation, store: Store | None = None) -> S.Reservation:
    bt = codes.BROADCASTING_BY_CODE.get(r.broadcasting_type, str(r.broadcasting_type))
    repeat = codes.REPEAT_BY_CODE.get(r.repeat_code, r.repeat_code)
    quality = codes.QUALITY_BY_CODE.get(r.quality_code, str(r.quality_code))
    name, genres = None, []
    if store and bt in codes.EPG_FILES:
        ch = [c for c in store.channels(bt) if c["service_id"] == r.service_id]
        name = ch[0]["name"] if ch else None
        if r.event_id is not None and (p := store.program(bt, r.service_id, r.event_id)):
            genres = _genres(p.genres)
    if not genres:
        genres = _genres_from_code(r.genre_code)
    return S.Reservation(id=r.id, title=r.title, start=r.start, end=r.start + timedelta(seconds=r.duration_sec),
                         duration_sec=r.duration_sec, broadcasting=bt, service_id=r.service_id, service_name=name,
                         event_id=r.event_id, tracks_program=r.event_id is not None, repeat=repeat,
                         repeat_label=codes.REPEAT_LABEL.get(repeat, repeat), quality=quality,
                         quality_label=codes.QUALITY_LABEL.get(quality, quality), recording=r.recording,
                         conflict=r.conflict, destination=r.destination, size_mb=r.size_mb,
                         created_by_app=r.creator == "2200", genres=genres)


def title_out(t: XTitle, store: Store | None = None) -> S.RecordedTitle:
    bt = codes.BROADCASTING_BY_CODE.get(t.broadcasting_type, str(t.broadcasting_type))
    name = None
    if store and bt in codes.EPG_FILES:
        ch = [c for c in store.channels(bt) if c["service_id"] == t.service_id]
        name = ch[0]["name"] if ch else None
    return S.RecordedTitle(id=t.id, title=t.title, start=t.start, duration_sec=t.duration_sec, broadcasting=bt,
                           service_id=t.service_id, service_name=name,
                           quality=codes.QUALITY_BY_CODE.get(t.quality_code, str(t.quality_code)), protected=t.protected,
                           is_new=t.is_new, destination=t.destination, size_mb=t.size_mb,
                           dlna_id=RecorderClient.cds_id(t.id), genres=_genres_from_code(t.genre_code))


class Bridge:
    """Application state: settings, the selected recorder (may be None until configured), store, EPG refresh."""

    def __init__(self, settings: Settings, recorder: RecorderClient | None, store: Store):
        self.settings, self.recorder, self.store = settings, recorder, store
        self.refresh_lock = asyncio.Lock()
        self.last_error: str | None = None
        self.http = httpx.AsyncClient(timeout=10.0)

    @property
    def configured(self) -> bool:
        return self.recorder is not None

    def require_recorder(self) -> RecorderClient:
        if self.recorder is None:
            raise HTTPException(503, "recorder not configured: call GET /api/v1/recorders/discover, then PUT /api/v1/recorder")
        return self.recorder

    async def discover(self) -> list[discovery.Candidate]:
        return await discovery.discover(self.http, networks=self.settings.scan_networks)

    async def set_recorder(self, host: str, persist: bool = True) -> RecorderClient:
        client = RecorderClient(host)
        try:
            info = await client.discover()
        except Exception as e:
            await client.close()
            raise HTTPException(400, f"no recorder answered at {host}: {e}")
        old, self.recorder = self.recorder, client
        if old is not None:
            await old.close()
        if persist:
            self.store.set_meta("recorder_host", host)
            self.store.set_meta("recorder_udn", info.udn)
            self.store.set_meta("recorder_name", info.friendly_name)
        return client

    async def resolve_recorder(self) -> None:
        """Startup: env var wins; else the saved host; if it moved, find it again by UDN."""
        if self.settings.recorder_host:
            try:
                await self.set_recorder(self.settings.recorder_host, persist=False)
            except HTTPException as e:
                log.warning("configured recorder unreachable: %s", e.detail)
            return
        saved_host, saved_udn = self.store.get_meta("recorder_host"), self.store.get_meta("recorder_udn")
        if saved_host:
            c = await discovery.probe(saved_host, self.http)
            if c and (not saved_udn or c.udn == saved_udn):
                await self.set_recorder(saved_host, persist=False)
                return
            log.warning("saved recorder %s not answering (or a different device); re-discovering", saved_host)
        if saved_udn:
            for c in await self.discover():
                if c.udn == saved_udn:
                    log.info("recorder %s moved to %s", saved_udn, c.host)
                    await self.set_recorder(c.host)
                    return
        log.warning("no recorder configured; discovery endpoints are available")

    async def refresh_epg(self) -> dict:
        recorder = self.require_recorder()
        if recorder.info is not None and not recorder.info.epg_capable:
            self.last_error = None
            return {"note": "this recorder does not provide an EPG (EPG_CAP is 00)", "epg_capable": False}
        async with self.refresh_lock:
            result = {}
            for bt in codes.EPG_FILES:
                try:
                    services = await recorder.fetch_epg(bt)
                except Exception as e:  # keep serving the cache
                    log.warning("EPG %s fetch failed: %s", bt, e)
                    self.last_error = f"{bt}: {e}"
                    result[bt] = {"error": str(e)}
                    continue
                if services is None:
                    result[bt] = {"programs": 0, "channels": 0, "note": "no channels"}
                    continue
                n = await asyncio.to_thread(self.store.replace_services, bt, services)
                result[bt] = {"programs": n, "channels": len(services)}
                try:
                    logos = await recorder.fetch_logos(bt)
                except Exception as e:  # logos are decoration; keep whatever is cached
                    log.warning("logo %s fetch failed: %s", bt, e)
                    logos = None
                if logos is not None:
                    await asyncio.to_thread(self.store.replace_logos, bt, logos)
                    result[bt]["logos"] = len(logos)
            self.last_error = None
            return result

    async def refresh_loop(self) -> None:
        first = self.settings.epg_refresh_on_start
        while True:
            if self.configured and first:
                try:
                    await self.refresh_epg()
                except Exception as e:
                    log.warning("EPG refresh failed: %s", e)
            first = True
            await asyncio.sleep(self.settings.epg_refresh_hours * 3600 if self.configured else 30)

    async def close(self) -> None:
        if self.recorder:
            await self.recorder.close()
        await self.http.aclose()


def _data_url(png: bytes | None) -> str | None:
    return "data:image/png;base64," + base64.b64encode(png).decode() if png else None


def create_app(settings: Settings | None = None, bridge: Bridge | None = None) -> FastAPI:
    settings = settings or Settings()
    token = settings.ensure_token()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        b = bridge
        if b is None:
            settings.ensure_db_dir()
            b = Bridge(settings, None, Store(settings.db_path))
            await b.resolve_recorder()
        app.state.bridge = b
        task = asyncio.create_task(b.refresh_loop()) if bridge is None else None
        try:
            yield
        finally:
            if task:
                task.cancel()
            if bridge is None:
                await b.close()

    app = FastAPI(title="recbridge", version="0.1.0", lifespan=lifespan)

    async def auth(creds: HTTPAuthorizationCredentials | None = Depends(bearer)) -> None:
        if creds is None or creds.credentials != token:
            raise HTTPException(401, "invalid token")

    def bridge_of(request: Request) -> Bridge:
        return request.app.state.bridge

    v1 = "/api/v1"

    @app.get(v1 + "/recorders/discover", response_model=list[S.RecorderCandidate], dependencies=[Depends(auth)])
    async def recorders_discover(request: Request):
        b = bridge_of(request)
        return [S.RecorderCandidate(**c.__dict__, selected=bool(b.recorder and b.recorder.host == c.host))
                for c in await b.discover()]

    @app.put(v1 + "/recorder", response_model=S.RecorderStatus, dependencies=[Depends(auth)])
    async def recorder_select(request: Request, req: S.RecorderSelect):
        b = bridge_of(request)
        await b.set_recorder(req.host)
        asyncio.get_running_loop().create_task(_safe_refresh(b))
        return await recorder_status(request)

    async def _safe_refresh(b: Bridge) -> None:
        try:
            await b.refresh_epg()
        except Exception as e:
            log.warning("EPG refresh after selecting recorder failed: %s", e)

    @app.get(v1 + "/recorder", response_model=S.RecorderStatus, dependencies=[Depends(auth)])
    async def recorder_status(request: Request):
        b = bridge_of(request)
        epg = b.store.summary()
        epg["last_error"] = b.last_error
        if b.recorder is None:
            return S.RecorderStatus(configured=False, host=b.store.get_meta("recorder_host"), epg=epg)
        info = b.recorder.info or await b.recorder.discover()
        fw = power = play = None
        try:
            async with b.recorder.lock:
                st = await b.recorder.xsrs.play_status()
                fw = await b.recorder.xsrs.firmware_version()
            power, play = st.get("powerstatus"), st.get("playstatus")
        except Exception as e:
            log.warning("status query failed: %s", e)
        return S.RecorderStatus(configured=True, host=info.host, friendly_name=info.friendly_name, model=info.model,
                                product=info.product, epg_capable=info.epg_capable, udn=info.udn, firmware=fw,
                                power=power, play=play, epg=epg)

    @app.post(v1 + "/recorder/power", dependencies=[Depends(auth)])
    async def recorder_power(request: Request):
        rec = bridge_of(request).require_recorder()
        async with rec.lock:
            return {"power": await rec.xsrs.power_on()}

    @app.get(v1 + "/defaults", response_model=S.Defaults, dependencies=[Depends(auth)])
    async def defaults(request: Request):
        s = bridge_of(request).settings
        return S.Defaults(quality=s.default_quality, repeat=s.default_repeat, qualities=codes.QUALITY_LABEL,
                          repeats=codes.REPEAT_LABEL, broadcastings=codes.BROADCASTING_LABEL, genres=codes.GENRE_LABEL)

    @app.post(v1 + "/epg/refresh", dependencies=[Depends(auth)])
    async def epg_refresh(request: Request):
        return await bridge_of(request).refresh_epg()

    @app.get(v1 + "/channels", response_model=list[S.Channel], dependencies=[Depends(auth)])
    async def channels(request: Request, broadcasting: S.Broadcasting | None = None):
        return [S.Channel(broadcasting=c["bt"], service_id=c["service_id"], name=c["name"], sort=c["sort"],
                          logo=_data_url(c["logo"]))
                for c in bridge_of(request).store.channels(broadcasting)]

    @app.get(v1 + "/programs", response_model=list[S.Program], dependencies=[Depends(auth)])
    async def programs(request: Request, broadcasting: S.Broadcasting | None = None, service_id: int | None = None,
                       date: str | None = Query(None, description="YYYY-MM-DD; TV day 04:00-04:00 JST"),
                       since: datetime | None = None, until: datetime | None = None, q: str | None = None,
                       compact: bool = Query(False, description="omit description/extended (for the grid view)"),
                       limit: int = Query(500, le=5000), offset: int = 0):
        store = bridge_of(request).store
        if date:
            since, until = store.day_range(datetime.fromisoformat(date).replace(tzinfo=JST))
        rows = store.programs(bt=broadcasting, service_id=service_id, since=since, until=until, query=q,
                              limit=limit, offset=offset)
        return [program_out(p, compact) for p in rows]

    @app.get(v1 + "/programs/now", response_model=list[S.Program], dependencies=[Depends(auth)])
    async def programs_now(request: Request, broadcasting: S.Broadcasting = "td"):
        return [program_out(p) for p in bridge_of(request).store.now_on_air(broadcasting)]

    @app.get(v1 + "/programs/{broadcasting}/{service_id}/{event_id}", response_model=S.Program, dependencies=[Depends(auth)])
    async def program(request: Request, broadcasting: S.Broadcasting, service_id: int, event_id: int):
        p = bridge_of(request).store.program(broadcasting, service_id, event_id)
        if not p:
            raise HTTPException(404, "program not found")
        return program_out(p)

    @app.get(v1 + "/reservations", response_model=list[S.Reservation], dependencies=[Depends(auth)])
    async def reservations(request: Request):
        b = bridge_of(request)
        rec = b.require_recorder()
        async with rec.lock:
            items = await rec.xsrs.list_reservations()
        return [reservation_out(r, b.store) for r in sorted(items, key=lambda r: r.start)]

    def _elements(b: Bridge, req: S.ReservationCreate) -> tuple[str, str]:
        start, duration, title = req.start, req.duration_sec, req.title
        if req.event_id is not None:
            p = b.store.program(req.broadcasting, req.service_id, req.event_id)
            if p is None and (start is None or duration is None):
                raise HTTPException(404, "program not in the cached EPG; give start and duration_sec explicitly")
            if p is not None:
                start = start or p.start
                duration = duration or int((p.end - p.start).total_seconds())
                title = title or p.title
        if start is None or duration is None:
            raise HTTPException(422, "start and duration_sec are required without event_id")
        if start.tzinfo is None:
            start = start.replace(tzinfo=JST)
        quality = req.quality or b.settings.default_quality
        repeat = req.repeat or b.settings.default_repeat
        el = build_create_elements(title=title or "録画", start=start, duration_sec=duration,
                                   repeat_code=codes.REPEAT[repeat], broadcasting_type=codes.BROADCASTING[req.broadcasting],
                                   service_id=req.service_id, quality_code=codes.QUALITY[quality], event_id=req.event_id)
        return el, title or "録画"

    @app.post(v1 + "/reservations/check", response_model=S.ConflictReport, dependencies=[Depends(auth)])
    async def reservation_check(request: Request, req: S.ReservationCreate):
        b = bridge_of(request)
        rec = b.require_recorder()
        el, _ = _elements(b, req)
        try:
            async with rec.lock:
                conflicts = await rec.xsrs.conflicts(el)
        except XsrsError as e:
            raise HTTPException(502, str(e))
        return S.ConflictReport(conflicts=[reservation_out(c, b.store) for c in conflicts], ok=not conflicts)

    @app.post(v1 + "/reservations", response_model=S.ReservationCreated, status_code=201, dependencies=[Depends(auth)])
    async def reservation_create(request: Request, req: S.ReservationCreate):
        b = bridge_of(request)
        rec = b.require_recorder()
        el, _ = _elements(b, req)
        try:
            async with rec.lock:
                conflicts = await rec.xsrs.conflicts(el)
                if conflicts and not req.force:
                    raise HTTPException(409, {"message": "conflicts with existing reservations",
                                              "conflicts": [reservation_out(c, b.store).model_dump(mode="json") for c in conflicts]})
                new_id = await rec.xsrs.create_reservation(el)
                items = await rec.xsrs.list_reservations()
        except XsrsError as e:
            raise HTTPException(502, str(e))
        created = next((r for r in items if r.id == new_id), None)
        if created is None:
            raise HTTPException(502, f"recorder returned id {new_id} but it is not in the list")
        return S.ReservationCreated(reservation=reservation_out(created, b.store),
                                    conflicts=[reservation_out(c, b.store) for c in conflicts])

    @app.patch(v1 + "/reservations/{reservation_id}", response_model=S.Reservation, dependencies=[Depends(auth)])
    async def reservation_update(request: Request, reservation_id: str, req: S.ReservationUpdate):
        b = bridge_of(request)
        rec = b.require_recorder()
        try:
            async with rec.lock:
                current = next((r for r in await rec.xsrs.list_reservations() if r.id == reservation_id), None)
                if current is None:
                    raise HTTPException(404, "reservation not found")
                quality = req.quality or codes.QUALITY_BY_CODE.get(current.quality_code, b.settings.default_quality)
                repeat = req.repeat or codes.REPEAT_BY_CODE.get(current.repeat_code, "none")
                start = req.start or current.start
                if start.tzinfo is None:
                    start = start.replace(tzinfo=JST)
                el = build_update_elements(reservation_id, title=req.title or current.title, start=start,
                                           duration_sec=req.duration_sec or current.duration_sec,
                                           repeat_code=codes.REPEAT[repeat], broadcasting_type=current.broadcasting_type,
                                           service_id=current.service_id, quality_code=codes.QUALITY[quality],
                                           event_id=current.event_id)
                await rec.xsrs.update_reservation(el)
                updated = next((r for r in await rec.xsrs.list_reservations() if r.id == reservation_id), None)
        except XsrsError as e:
            raise HTTPException(502, str(e))
        if updated is None:
            raise HTTPException(502, "reservation disappeared after update")
        return reservation_out(updated, b.store)

    @app.delete(v1 + "/reservations/{reservation_id}", status_code=204, dependencies=[Depends(auth)])
    async def reservation_delete(request: Request, reservation_id: str):
        rec = bridge_of(request).require_recorder()
        try:
            async with rec.lock:
                await rec.xsrs.delete_reservation(reservation_id)
        except XsrsError as e:
            raise HTTPException(502 if e.code not in ("701", "801") else 404, str(e))

    @app.get(v1 + "/titles", response_model=list[S.RecordedTitle], dependencies=[Depends(auth)])
    async def titles(request: Request, limit: int = Query(100, le=500), offset: int = 0):
        b = bridge_of(request)
        rec = b.require_recorder()
        async with rec.lock:
            items = await rec.xsrs.list_titles(count=limit, start=offset)
        return [title_out(t, b.store) for t in items]

    def _playback(st: dict) -> S.PlaybackStatus:
        return S.PlaybackStatus(power=st.get("powerstatus"), play=st.get("playstatus"), title_id=st.get("item"),
                                position_sec=int(st["position"]) if st.get("position", "").isdigit() else None,
                                chapter=int(st["chapterNumber"]) if st.get("chapterNumber", "").isdigit() else None)

    async def _ensure_on(rec: RecorderClient) -> dict:
        """Playback needs the recorder fully on; wake it and wait up to ~15 s."""
        st = await rec.xsrs.play_status()
        if st.get("powerstatus") == "PowerOn":
            return st
        await rec.xsrs.power_on()
        for _ in range(15):
            await asyncio.sleep(1)
            st = await rec.xsrs.play_status()
            if st.get("powerstatus") == "PowerOn":
                return st
        raise HTTPException(503, "recorder did not power on")

    @app.get(v1 + "/recorder/playback", response_model=S.PlaybackStatus, dependencies=[Depends(auth)])
    async def playback_status(request: Request):
        rec = bridge_of(request).require_recorder()
        async with rec.lock:
            return _playback(await rec.xsrs.play_status())

    @app.post(v1 + "/recorder/playback", response_model=S.PlaybackStatus, dependencies=[Depends(auth)])
    async def playback_control(request: Request, req: S.PlaybackControl):
        rec = bridge_of(request).require_recorder()
        try:
            async with rec.lock:
                st = await rec.xsrs.play_status()
                title_id = st.get("item")
                if not title_id:
                    raise HTTPException(409, "nothing is playing")
                paused = st.get("playstatus") == "Paused"
                if req.operation == "resume" and not paused:
                    raise HTTPException(409, "not paused")
                # There is no resume operation; "pause" toggles between Paused and Playing.
                await rec.xsrs.play_control(title_id, "pause" if req.operation == "resume" else req.operation)
                await asyncio.sleep(1)
                return _playback(await rec.xsrs.play_status())
        except XsrsError as e:
            raise HTTPException(502, str(e))

    @app.post(v1 + "/titles/{title_id}/play", response_model=S.PlaybackStatus, dependencies=[Depends(auth)])
    async def title_play(request: Request, title_id: str, position_sec: int = Query(0, ge=0)):
        """Start playing a recorded title on the TV connected to the recorder."""
        rec = bridge_of(request).require_recorder()
        try:
            async with rec.lock:
                await _ensure_on(rec)
                await rec.xsrs.play_control(title_id, "play", position_sec)
                await asyncio.sleep(2)
                return _playback(await rec.xsrs.play_status())
        except XsrsError as e:
            raise HTTPException(404 if e.code in ("701", "803") else 502, str(e))

    @app.get(v1 + "/titles/{title_id}", response_model=S.TitleDetail, dependencies=[Depends(auth)])
    async def title_detail(request: Request, title_id: str):
        rec = bridge_of(request).require_recorder()
        try:
            async with rec.lock:
                detail = await rec.xsrs.title_detail(title_id)
        except XsrsError as e:
            raise HTTPException(404 if e.code in ("701", "803", "820") else 502, str(e))
        return S.TitleDetail(id=title_id, summary=detail["summary"], details=detail["details"])

    static_dir = Path(settings.static_dir) if settings.static_dir else Path(__file__).resolve().parents[3] / "web" / "dist"
    if static_dir.is_dir():
        # The built PWA. Mounted last so /api/* keeps precedence; same origin means no CORS.
        app.mount("/", StaticFiles(directory=str(static_dir), html=True), name="web")
        log.info("serving web app from %s", static_dir)

    return app
