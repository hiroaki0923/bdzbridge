"""Application state: settings, the selected recorder (None until configured), the store, notifier, background jobs."""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime

import httpx
from fastapi import HTTPException

from .api.serializers import title_out
from .autorec import run_rules
from .config import Settings
from .monitor import run_checks
from .notify import Notifier
from .recorder import codes, discovery, wol
from .recorder.client import RecorderClient
from .recorder.epg import JST
from .recorder.series import same_title_key, summary_key
from .recorder.xsrs import RecordedTitle as XTitle
from .recorder.xsrs import XsrsError, build_title_update_elements
from .store import Store

log = logging.getLogger("bdzbridge")


class Bridge:
    """Application state: settings, the selected recorder (may be None until configured), store, EPG refresh."""

    def __init__(self, settings: Settings, recorder: RecorderClient | None, store: Store):
        self.settings, self.recorder, self.store = settings, recorder, store
        self.refresh_lock = asyncio.Lock()
        self.last_error: str | None = None
        self.http = httpx.AsyncClient(timeout=10.0)
        self.notifier = Notifier(settings, self.http)
        self.clock = lambda: datetime.now(JST)  # tests override this
        self.last_autorec: dict | None = None
        self._titles: tuple[float, list[XTitle]] | None = None  # cached full title list (grouping, bulk operations)
        self.jobs: dict[str, dict] = {}  # bulk delete jobs by id

    async def all_titles(self, max_age: float = 300) -> list[XTitle]:
        rec = self.require_recorder()
        if self._titles and time.monotonic() - self._titles[0] < max_age:
            return self._titles[1]
        async with rec.lock:
            items = await rec.xsrs.list_titles_all()
        self._titles = (time.monotonic(), items)
        return items

    def forget_titles(self) -> None:
        self._titles = None

    async def run_duplicates_job(self, job: dict) -> None:
        """Group recordings that look like copies of one broadcast (same title and length, then the same programme
        text, which the recorder is asked for one title at a time and cached)."""
        rec = self.recorder
        try:
            groups: dict[str, list[XTitle]] = {}
            for t in await self.all_titles():
                groups.setdefault(same_title_key(t.title), []).append(t)
            candidates: list[list[XTitle]] = []
            for v in groups.values():
                if len(v) < 2:
                    continue
                v = sorted(v, key=lambda t: t.duration_sec)
                cluster = [v[0]]
                for t in v[1:]:
                    if abs(t.duration_sec - cluster[-1].duration_sec) <= 120:
                        cluster.append(t)
                    else:
                        if len(cluster) > 1:
                            candidates.append(cluster)
                        cluster = [t]
                if len(cluster) > 1:
                    candidates.append(cluster)
            job["total"] = sum(len(c) for c in candidates)
            sets: list[dict] = []
            for members in candidates:
                keys: dict[str, str] = {}
                for t in members:
                    summ = self.store.title_summary(t.id)
                    if summ is None:
                        try:
                            async with rec.lock:
                                summ = (await rec.xsrs.title_detail(t.id)).get("summary") or ""
                        except Exception as e:
                            log.debug("no detail for %s: %s", t.id, e)
                            summ = ""
                        self.store.set_title_summary(t.id, summ)
                    keys[t.id] = summary_key(summ)
                    job["done"] += 1
                by_summary: dict[str, list[XTitle]] = {}
                for t in members:
                    by_summary.setdefault(keys[t.id], []).append(t)
                for k, same in by_summary.items():
                    if len(same) > 1:
                        sets.append(self._duplicate_set(same, "high" if k else "low"))
            job["sets"] = sorted(sets, key=lambda s: s["size_mb"], reverse=True)
        except Exception as e:
            job["error"] = str(e)
            log.warning("duplicate scan failed: %s", e)
        finally:
            job["finished"] = True

    def _duplicate_set(self, members: list[XTitle], confidence: str) -> dict:
        def rank(t: XTitle):  # smaller is better to keep
            quality = 0 if t.quality_code == 100 else t.quality_code  # DR first, then the AVC modes in order
            return (not t.protected, (t.resume_sec or 0) == 0, quality, t.start)
        keep = min(members, key=rank)
        others = [m for m in members if m.id != keep.id]
        quality = lambda t: 0 if t.quality_code == 100 else t.quality_code
        reasons = {}
        for t in members:
            if t.id == keep.id:
                if t.protected:
                    reasons[t.id] = "保護中"
                elif (t.resume_sec or 0) > 0:
                    reasons[t.id] = "視聴途中"
                elif all(t.start < o.start for o in others):
                    reasons[t.id] = "先に放送"
                elif any(quality(t) < quality(o) for o in others):
                    reasons[t.id] = "高画質"
                else:
                    reasons[t.id] = "同じ内容"
            elif t.protected:
                reasons[t.id] = "保護中"
            elif t.start > keep.start:
                reasons[t.id] = "後の放送"
            elif quality(t) > quality(keep):
                reasons[t.id] = "低画質"
            else:
                reasons[t.id] = "同じ内容"
        return {"title": members[0].title, "confidence": confidence,
                "size_mb": sum(t.size_mb or 0 for t in members), "items": [title_out(t, self.store) for t in members],
                "keep": keep.id, "suggest_delete": [t.id for t in members if t.id != keep.id and not t.protected], "reasons": reasons}

    async def run_protect_job(self, job: dict, ids: list[str], protected: bool) -> None:
        """Set or clear the protect flag on many recordings, one X_UpdateTitle at a time."""
        rec = self.recorder
        try:
            known = {t.id: t for t in await self.all_titles()}
            for tid in ids:
                t = known.get(tid)
                if t is None:
                    job["skipped"].append({"id": tid, "reason": "not found"})
                elif t.protected == protected:
                    job["skipped"].append({"id": tid, "reason": "unchanged"})
                else:
                    try:
                        async with rec.lock:
                            await rec.xsrs.update_title(build_title_update_elements(tid, protected=protected))
                        job["changed"].append(tid)
                    except XsrsError as e:
                        job["skipped"].append({"id": tid, "reason": str(e)})
                job["done"] += 1
        except Exception as e:
            job["error"] = str(e)
            log.warning("protect job %s failed: %s", job["id"], e)
        finally:
            job["finished"] = True
            self.forget_titles()

    async def run_delete_job(self, job: dict, ids: list[str]) -> None:
        """Delete recordings one by one (each takes the recorder a few seconds) while `job` reports progress."""
        rec = self.recorder
        try:
            known = {t.id: t for t in await self.all_titles()}
            for tid in ids:
                t = known.get(tid)
                if t is None:
                    job["skipped"].append({"id": tid, "reason": "not found"})
                elif t.protected:
                    job["skipped"].append({"id": tid, "reason": "protected"})
                else:
                    try:
                        async with rec.lock:
                            await rec.xsrs.delete_title(tid)
                        job["deleted"].append(tid)
                    except XsrsError as e:
                        job["skipped"].append({"id": tid, "reason": str(e)})
                job["done"] += 1
        except Exception as e:
            job["error"] = str(e)
            log.warning("delete job %s failed: %s", job["id"], e)
        finally:
            job["finished"] = True
            self.forget_titles()

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
        if not self.settings.recorder_mac and (mac := await wol.mac_for(host)):
            self.store.set_meta("recorder_mac", mac)  # for Wake-on-LAN later
        return client

    @property
    def mac(self) -> str | None:
        return self.settings.recorder_mac or self.store.get_meta("recorder_mac")

    async def reachable(self) -> bool:
        return self.recorder is not None and await wol.port_open(self.recorder.host, 64220)

    async def wake(self) -> bool:
        """Wake-on-LAN, then wait for the reservation service to answer. False when it stays silent."""
        rec = self.require_recorder()
        if not self.mac:
            raise HTTPException(409, "the recorder's MAC address is not known; set BDZBRIDGE_RECORDER_MAC")
        if await wol.port_open(rec.host, 64220):
            return True
        return await wol.wake(rec.host, self.mac)

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
        if any("programs" in v and v["programs"] for v in result.values()):
            try:
                self.last_autorec = await run_rules(self, self.clock())
                result["auto"] = self.last_autorec
            except Exception as e:
                log.warning("auto-reservation failed: %s", e)
            try:
                result["monitor"] = await run_checks(self)
            except Exception as e:
                log.warning("monitor failed: %s", e)
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
