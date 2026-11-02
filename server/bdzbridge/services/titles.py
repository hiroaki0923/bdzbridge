"""Recorded titles: the cached full list, programme groups, duplicate detection, and the bulk jobs."""
from __future__ import annotations

import logging
import time
from collections.abc import Iterable
from datetime import date, datetime, timedelta
from typing import TYPE_CHECKING

import httpx
from fastapi import HTTPException

from ..api import schemas as S
from ..api.serializers import title_out
from ..jobs import Job
from ..recorder.epg import JST
from ..recorder.series import same_title_key, series_key, series_name, summary_key
from ..recorder.xsrs import RecordedTitle as XTitle
from ..recorder.xsrs import XsrsError, build_title_update_elements
from ..store import Store
from . import usb

if TYPE_CHECKING:
    from ..state import Bridge

log = logging.getLogger("bdzbridge.titles")

USB = "USBHDD"
DISK_CHANGED = "録画先のディスクが変わったため、この操作は行っていません。一覧を読み直してから、もう一度お試しください"
RECORDING_ON_USB = "録画中のため保護も削除もできません。番組が終わってから一覧を読み直してください"
NOT_PLAYED_WHILE_RECORDING = "録画中のため再生できません。番組が終わってから一覧を読み直してください"


async def all_titles(bridge, max_age: float = 300) -> list[XTitle]:
    """Every recording on the internal disk and on a USB disk that takes recordings, newest first. The recorder lists
    them apart. The internal disk's rows stand whatever becomes of the USB disk's read."""
    rec = bridge.require_recorder()
    if bridge.titles_cache and time.monotonic() - bridge.titles_cache[0] < max_age:
        return bridge.titles_cache[1]
    async with rec.lock:
        items = await rec.xsrs.list_titles_all()
    items = sorted(items + await _usb_titles(bridge), key=lambda t: t.start, reverse=True)
    bridge.titles_cache = (time.monotonic(), items)
    return items


async def _usb_titles(bridge) -> list[XTitle]:
    """The USB disk's rows, and the disk they were read from noted. When they cannot be read, the rows held stay
    while that disk is still in the slot: nothing said they had gone, and the next read asks again."""
    rec, disk = bridge.recorder, await usb.settled(bridge)
    held = [t for t in bridge.titles_cache[1] if t.destination == USB] if bridge.titles_cache else bridge.usb_titles_held
    still = disk is not None and bridge.titles_disk is not None and disk.identity == bridge.titles_disk.identity
    if disk is None or not disk.takes_recordings:
        bridge.titles_disk = None
        return []
    try:
        async with rec.lock:
            rows = await rec.xsrs.list_titles_all(destination=USB)
    except (XsrsError, httpx.HTTPError) as e:
        log.warning("the USB disk's recordings could not be read: %s", e)
        return held if still else []
    bridge.titles_disk = disk
    return rows


def forget_titles(bridge) -> None:
    if bridge.titles_cache:
        bridge.usb_titles_held = [t for t in bridge.titles_cache[1] if t.destination == USB]
    bridge.titles_cache = None


async def why_not_altering(bridge, t: XTitle) -> str | None:
    """Why nothing is to be written to a recording now, or None. Only of the USB disk's rows. An id means something
    only on the disk it was read from, and nothing says a disk was swapped or pulled, so the slot is read before each
    write. A row still recording is left alone too, as its id changes when it ends."""
    if t.destination != USB:
        return None
    disk = await usb.settled(bridge)
    if disk is None or not disk.takes_recordings or bridge.titles_disk is None or disk.identity != bridge.titles_disk.identity:
        forget_titles(bridge)
        return DISK_CHANGED
    return RECORDING_ON_USB if t.recording else None


async def row_or_refuse(bridge, title_id: str, playing: bool = False) -> XTitle | None:
    """The row of a recording about to be written to, or a 409 that says why it is not to be. None for an id not in
    the list, which goes on to the recorder as it always has."""
    t = next((x for x in await all_titles(bridge) if x.id == title_id), None)
    if t is not None and (why := await why_not_altering(bridge, t)):
        raise HTTPException(409, NOT_PLAYED_WHILE_RECORDING if playing and why == RECORDING_ON_USB else why)
    return t


def duplicate_candidates(titles: list[XTitle]) -> list[list[XTitle]]:
    """Recordings that could be copies of one broadcast: the same title, then lengths within two minutes of
    each other. Pure, so it can be checked without a recorder (docs/port/titles.json)."""
    groups: dict[str, list[XTitle]] = {}
    for t in titles:
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
    return candidates


# A programme text shorter than this says what kind of programme it is (ニュース, 天気予報, a mini anime's one line)
# rather than what one broadcast was about, so two recordings sharing it may be any two episodes.
FIXED_BLURB_CHARS = 20


def broadcast_day(moment: datetime) -> date:
    """The broadcast day a moment belongs to: 04:00 to 04:00 JST, so a late-night show is on the evening before."""
    return (moment.astimezone(JST) - timedelta(hours=4)).date()


def fixed_blurbs(guide: Iterable[tuple[str, str, datetime]], title_keys: set[str] | None = None) -> set[tuple[str, str]]:
    """The titles whose programme text the guide repeats on two or more broadcast days, as (same_title_key,
    summary_key) pairs; `guide` is (title, description, start) for each programme.

    Some programmes carry one blurb every time -- a daily three-minute show, a mini anime -- and two recordings
    of them agree on the title, the length and the text without being the same broadcast. The guide is where
    that shows: the same title with the same text on different days. Two showings on one day do not count, since
    a programme shown again the same day is most likely the same episode. A re-run of one episode later in the
    week looks the same as a fixed blurb and is taken for one, which errs the safe way: it is left unticked.
    `title_keys` narrows it to the titles asked about, so that the rest of the guide's text is not normalised."""
    keys: dict[str, str] = {}
    days: dict[tuple[str, str], set[date]] = {}
    for title, summary, start in guide:
        tk = keys.get(title)
        if tk is None:
            tk = keys[title] = same_title_key(title)
        if title_keys is not None and tk not in title_keys:
            continue
        sk = summary_key(summary)
        if sk:
            days.setdefault((tk, sk), set()).add(broadcast_day(start))
    return {blurb for blurb, seen in days.items() if len(seen) > 1}


def _confidence(title_key: str, key: str, fixed: set[tuple[str, str]]) -> str:
    if not key:
        return "low"
    if len(key) < FIXED_BLURB_CHARS or (title_key, key) in fixed:
        return "boilerplate"
    return "high"


def duplicate_sets(candidates: list[list[XTitle]], summaries: dict[str, str], store: Store | None = None,
                   fixed: set[tuple[str, str]] = frozenset()) -> list[dict]:
    """The sets themselves, once each candidate's programme text is known. Recordings whose text matches are
    the same broadcast for certain ("high"), unless the text is one the programme carries every time
    ("boilerplate": shorter than FIXED_BLURB_CHARS, or among `fixed`, from fixed_blurbs); with no text at all
    only the title and the length agree ("low")."""
    sets: list[dict] = []
    for members in candidates:
        title_key = same_title_key(members[0].title)  # a candidate is made of one title key
        keys = {t.id: summary_key(summaries.get(t.id, "")) for t in members}
        by_summary: dict[str, list[XTitle]] = {}
        for t in members:
            by_summary.setdefault(keys[t.id], []).append(t)
        for k, same in by_summary.items():
            if len(same) > 1:
                sets.append(duplicate_set(store, same, _confidence(title_key, k, fixed)))
    return sorted(sets, key=lambda s: s["size_mb"], reverse=True)


def _summary_key(bridge, t: XTitle) -> str:
    """What a programme text is kept under. Whether two USB disks use the same ids has not been seen, so a USB row's
    goes with the disk it was read from."""
    return f"{bridge.titles_disk.registered}:{t.id}" if t.destination == USB and bridge.titles_disk else t.id


async def scan_duplicates(bridge, job: Job) -> None:
    """Group recordings that look like copies of one broadcast (same title and length, then the same programme
    text, which the recorder is asked for one title at a time and cached; the guide tells a text that is the same
    every time). Only a text that was read is kept, an empty one among them: a recording whose read failed is
    left out of the comparison and counted, and asked for again next time, and one the recorder no longer has
    (820) leaves the list. Result: {"sets": [...], "unread": n}."""
    rec = bridge.recorder
    bridge.store.clear_blank_summaries_once()
    titles = [t for t in await all_titles(bridge) if not (t.destination == USB and t.recording)]
    candidates = duplicate_candidates(titles)
    job.total = sum(len(c) for c in candidates)
    summaries: dict[str, str] = {}
    gone: set[str] = set()
    for members in candidates:
        for t in members:
            key = _summary_key(bridge, t)
            summ = bridge.store.title_summary(key)
            if summ is None:
                try:
                    async with rec.lock:
                        summ = (await rec.xsrs.title_detail(t.id)).get("summary") or ""
                    bridge.store.set_title_summary(key, summ)
                except (XsrsError, httpx.HTTPError) as e:
                    log.debug("no detail for %s: %s", t.id, e)
                    if isinstance(e, XsrsError) and e.code == "820":
                        gone.add(t.id)
            if summ is not None:
                summaries[t.id] = summ
            job.step()
    if gone:
        forget_titles(bridge)
    read = [[t for t in members if t.id in summaries] for members in candidates]
    job.result["unread"] = sum(len(c) for c in candidates) - sum(len(m) for m in read) - len(gone)
    read = [members for members in read if len(members) > 1]
    fixed = fixed_blurbs(bridge.store.guide_blurbs(), {same_title_key(members[0].title) for members in read})
    job.result["sets"] = duplicate_sets(read, summaries, bridge.store, fixed)


async def protect_titles(bridge, job: Job, ids: list[str], protected: bool) -> None:
    """Set or clear the protect flag on many recordings, one X_UpdateTitle at a time.
    Result: {"changed": [ids], "skipped": [{"id", "reason"}], "protected": bool} (the direction, for a client that picks the job up later)."""
    rec = bridge.recorder
    try:
        known = {t.id: t for t in await all_titles(bridge)}
        for n, tid in enumerate(ids):
            t = known.get(tid)
            why = await why_not_altering(bridge, t) if t else None
            if t is None:
                job.result["skipped"].append({"id": tid, "reason": "not found"})
            elif why:
                job.result["skipped"] += [{"id": i, "reason": why} for i in (ids[n:] if why == DISK_CHANGED else [tid])]
                if why == DISK_CHANGED:
                    break
            elif t.protected == protected:
                job.result["skipped"].append({"id": tid, "reason": "unchanged"})
            else:
                try:
                    async with rec.lock:
                        await rec.xsrs.update_title(build_title_update_elements(tid, protected=protected))
                    job.result["changed"].append(tid)
                except (XsrsError, httpx.HTTPError) as e:  # a slow or dropped request costs one title, not the job
                    job.result["skipped"].append({"id": tid, "reason": str(e) or type(e).__name__})
            job.step()
    finally:
        forget_titles(bridge)


async def delete_titles(bridge, job: Job, ids: list[str]) -> None:
    """Delete recordings one by one (each takes the recorder a few seconds).
    Result: {"deleted": [ids], "skipped": [{"id", "reason"}]}; protected, in-progress and unknown ids are skipped, and
    the job stops at a USB row whose disk has changed."""
    rec = bridge.recorder
    try:
        known = {t.id: t for t in await all_titles(bridge)}
        for n, tid in enumerate(ids):
            t = known.get(tid)
            why = await why_not_altering(bridge, t) if t else None
            if t is None:
                job.result["skipped"].append({"id": tid, "reason": "not found"})
            elif why:
                job.result["skipped"] += [{"id": i, "reason": why} for i in (ids[n:] if why == DISK_CHANGED else [tid])]
                if why == DISK_CHANGED:
                    break
            elif t.protected:
                job.result["skipped"].append({"id": tid, "reason": "protected"})
            elif t.recording:
                job.result["skipped"].append({"id": tid, "reason": "recording"})
            else:
                try:
                    async with rec.lock:
                        await rec.xsrs.delete_title(tid)
                    job.result["deleted"].append(tid)
                except (XsrsError, httpx.HTTPError) as e:  # a slow or dropped request costs one title, not the job
                    job.result["skipped"].append({"id": tid, "reason": str(e) or type(e).__name__})
            job.step()
    finally:
        forget_titles(bridge)


def duplicate_set(store: Store | None, members: list[XTitle], confidence: str) -> dict:
    members = sorted(members, key=lambda t: t.start)  # broadcast order, so the copy to keep is normally the first row

    def rank(t: XTitle):  # smaller is better to keep
        quality = 0 if t.quality_code == 100 else t.quality_code  # DR first, then the AVC modes in order
        return (not t.protected and not t.recording, (t.resume_sec or 0) == 0, quality, t.start)
    keep = min(members, key=rank)
    others = [m for m in members if m.id != keep.id]
    quality = lambda t: 0 if t.quality_code == 100 else t.quality_code
    reasons = {}
    for t in members:
        if t.id == keep.id:
            if t.protected:
                reasons[t.id] = "保護中"
            elif t.recording:
                reasons[t.id] = "録画中"
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
        elif t.recording:
            reasons[t.id] = "録画中"
        elif t.start > keep.start:
            reasons[t.id] = "後の放送"
        elif quality(t) > quality(keep):
            reasons[t.id] = "低画質"
        else:
            reasons[t.id] = "同じ内容"
    return {"title": members[0].title, "confidence": confidence,
            "size_mb": sum(t.size_mb or 0 for t in members),
            "items": [title_out(t, store).model_dump(mode="json") for t in members],
            "keep": keep.id,
            "suggest_delete": [t.id for t in members if t.id != keep.id and not t.protected and not t.recording],
            "reasons": reasons}

async def groups(bridge: Bridge, genre: int | None = None) -> list[S.TitleGroup]:
    """Recorded titles grouped into programmes by their names, newest group first."""
    return group_titles(await all_titles(bridge), genre)


def group_titles(titles: list[XTitle], genre: int | None = None) -> list[S.TitleGroup]:
    """The grouping itself, over a plain list, so it can be checked without a recorder (docs/port/titles.json)."""
    groups: dict[str, dict] = {}
    for t in titles:
        if genre is not None and (t.genre_code is None or t.genre_code >> 4 != genre):
            continue
        key = series_key(t.title)
        end = t.start + timedelta(seconds=t.duration_sec)
        g = groups.get(key)
        if g is None:
            g = groups[key] = {"names": {}, "count": 0, "size_mb": 0, "latest": t.start, "earliest": t.start,
                               "last_end": end, "protected": 0, "new": 0}
        name = series_name(t.title)
        g["names"][name] = g["names"].get(name, 0) + 1
        g["count"] += 1
        g["size_mb"] += t.size_mb or 0
        g["latest"], g["earliest"] = max(g["latest"], t.start), min(g["earliest"], t.start)
        g["last_end"] = max(g["last_end"], end)
        g["protected"] += int(t.protected)
        g["new"] += int(t.is_new)
    out = [S.TitleGroup(key=k, name=max(g["names"], key=g["names"].get), count=g["count"], size_mb=g["size_mb"],
                        latest=g["latest"], earliest=g["earliest"], last_end=g["last_end"],
                        protected_count=g["protected"], new_count=g["new"])
           for k, g in groups.items()]
    return sorted(out, key=lambda g: g.latest, reverse=True)
