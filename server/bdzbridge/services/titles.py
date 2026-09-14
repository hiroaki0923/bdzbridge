"""Recorded titles: the cached full list, programme groups, duplicate detection, and the bulk jobs."""
from __future__ import annotations

import logging
import time
from typing import TYPE_CHECKING

from ..api import schemas as S
from ..api.serializers import title_out
from ..jobs import Job
from ..recorder.series import same_title_key, series_key, series_name, summary_key
from ..recorder.xsrs import RecordedTitle as XTitle
from ..recorder.xsrs import XsrsError, build_title_update_elements
from ..store import Store

if TYPE_CHECKING:
    from ..state import Bridge

log = logging.getLogger("bdzbridge.titles")


async def all_titles(bridge, max_age: float = 300) -> list[XTitle]:
    rec = bridge.require_recorder()
    if bridge.titles_cache and time.monotonic() - bridge.titles_cache[0] < max_age:
        return bridge.titles_cache[1]
    async with rec.lock:
        items = await rec.xsrs.list_titles_all()
    bridge.titles_cache = (time.monotonic(), items)
    return items


def forget_titles(bridge) -> None:
    bridge.titles_cache = None


async def scan_duplicates(bridge, job: Job) -> None:
    """Group recordings that look like copies of one broadcast (same title and length, then the same programme
    text, which the recorder is asked for one title at a time and cached). Result: {"sets": [...]}."""
    rec = bridge.recorder
    groups: dict[str, list[XTitle]] = {}
    for t in await all_titles(bridge):
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
    job.total = sum(len(c) for c in candidates)
    sets: list[dict] = []
    for members in candidates:
        keys: dict[str, str] = {}
        for t in members:
            summ = bridge.store.title_summary(t.id)
            if summ is None:
                try:
                    async with rec.lock:
                        summ = (await rec.xsrs.title_detail(t.id)).get("summary") or ""
                except Exception as e:
                    log.debug("no detail for %s: %s", t.id, e)
                    summ = ""
                bridge.store.set_title_summary(t.id, summ)
            keys[t.id] = summary_key(summ)
            job.step()
        by_summary: dict[str, list[XTitle]] = {}
        for t in members:
            by_summary.setdefault(keys[t.id], []).append(t)
        for k, same in by_summary.items():
            if len(same) > 1:
                sets.append(duplicate_set(bridge.store, same, "high" if k else "low"))
    job.result["sets"] = sorted(sets, key=lambda s: s["size_mb"], reverse=True)


async def protect_titles(bridge, job: Job, ids: list[str], protected: bool) -> None:
    """Set or clear the protect flag on many recordings, one X_UpdateTitle at a time.
    Result: {"changed": [ids], "skipped": [{"id", "reason"}]}."""
    rec = bridge.recorder
    try:
        known = {t.id: t for t in await all_titles(bridge)}
        for tid in ids:
            t = known.get(tid)
            if t is None:
                job.result["skipped"].append({"id": tid, "reason": "not found"})
            elif t.protected == protected:
                job.result["skipped"].append({"id": tid, "reason": "unchanged"})
            else:
                try:
                    async with rec.lock:
                        await rec.xsrs.update_title(build_title_update_elements(tid, protected=protected))
                    job.result["changed"].append(tid)
                except XsrsError as e:
                    job.result["skipped"].append({"id": tid, "reason": str(e)})
            job.step()
    finally:
        forget_titles(bridge)


async def delete_titles(bridge, job: Job, ids: list[str]) -> None:
    """Delete recordings one by one (each takes the recorder a few seconds).
    Result: {"deleted": [ids], "skipped": [{"id", "reason"}]}; protected and unknown ids are skipped."""
    rec = bridge.recorder
    try:
        known = {t.id: t for t in await all_titles(bridge)}
        for tid in ids:
            t = known.get(tid)
            if t is None:
                job.result["skipped"].append({"id": tid, "reason": "not found"})
            elif t.protected:
                job.result["skipped"].append({"id": tid, "reason": "protected"})
            else:
                try:
                    async with rec.lock:
                        await rec.xsrs.delete_title(tid)
                    job.result["deleted"].append(tid)
                except XsrsError as e:
                    job.result["skipped"].append({"id": tid, "reason": str(e)})
            job.step()
    finally:
        forget_titles(bridge)


def duplicate_set(store: Store, members: list[XTitle], confidence: str) -> dict:
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
            "size_mb": sum(t.size_mb or 0 for t in members),
            "items": [title_out(t, store).model_dump(mode="json") for t in members],
            "keep": keep.id, "suggest_delete": [t.id for t in members if t.id != keep.id and not t.protected], "reasons": reasons}

async def groups(bridge: Bridge, genre: int | None = None) -> list[S.TitleGroup]:
    """Recorded titles grouped into programmes by their names, newest group first."""
    groups: dict[str, dict] = {}
    for t in await all_titles(bridge):
        if genre is not None and (t.genre_code is None or t.genre_code >> 4 != genre):
            continue
        key = series_key(t.title)
        g = groups.get(key)
        if g is None:
            g = groups[key] = {"names": {}, "count": 0, "size_mb": 0, "latest": t.start, "earliest": t.start, "protected": 0, "new": 0}
        name = series_name(t.title)
        g["names"][name] = g["names"].get(name, 0) + 1
        g["count"] += 1
        g["size_mb"] += t.size_mb or 0
        g["latest"], g["earliest"] = max(g["latest"], t.start), min(g["earliest"], t.start)
        g["protected"] += int(t.protected)
        g["new"] += int(t.is_new)
    out = [S.TitleGroup(key=k, name=max(g["names"], key=g["names"].get), count=g["count"], size_mb=g["size_mb"],
                        latest=g["latest"], earliest=g["earliest"], protected_count=g["protected"], new_count=g["new"])
           for k, g in groups.items()]
    return sorted(out, key=lambda g: g.latest, reverse=True)
