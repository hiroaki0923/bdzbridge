"""Recorded titles: listing, groups, duplicates, bulk jobs, playback, protection, deletion."""
from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from ...recorder.client import RecorderClient
from ...recorder.series import series_key
from ...recorder.xsrs import (
    XsrsError,
    build_title_update_elements,
)
from ...services import session
from ...services import titles as svc
from .. import schemas as S
from ..deps import auth, bridge_of
from ..serializers import title_out

router = APIRouter(prefix="/api/v1", tags=["titles"], dependencies=[Depends(auth)])


@router.get("/titles", response_model=list[S.RecordedTitle])
async def titles(request: Request, limit: int = Query(100, le=500), offset: int = 0,
                 series: str | None = Query(None, description="only titles with this grouping key (see /titles/groups)")):
    b = bridge_of(request)
    rec = b.require_recorder()
    if series is not None:
        items = [t for t in await svc.all_titles(b) if series_key(t.title) == series][offset:offset + limit]
    else:
        async with rec.lock:
            items = await rec.xsrs.list_titles(count=limit, start=offset)
    return [title_out(t, b.store) for t in items]

@router.get("/titles/groups", response_model=list[S.TitleGroup])
async def title_groups(request: Request, genre: int | None = Query(None, description="ARIB level-1 genre code"),
                       refresh: bool = Query(False, description="re-read the title list from the recorder")):
    """Recorded titles grouped into programmes by their names, newest group first."""
    b = bridge_of(request)
    if refresh:
        svc.forget_titles(b)
    return await svc.groups(b, genre)

@router.post("/titles/delete", response_model=S.Job, status_code=202)
async def titles_delete(request: Request, req: S.TitlesDelete):
    """Start deleting several recordings (a few seconds each); poll GET /jobs/{id}, cancel with POST /jobs/{id}/cancel.
    Protected and unknown ids are skipped, not failed."""
    b = bridge_of(request)
    b.require_recorder()
    return b.jobs.start("delete", lambda job: svc.delete_titles(b, job, req.ids), total=len(req.ids),
                        result={"deleted": [], "skipped": []}).to_dict()


@router.post("/titles/protect", response_model=S.Job, status_code=202)
async def titles_protect(request: Request, req: S.TitlesProtect):
    """Start protecting or unprotecting several recordings; poll GET /jobs/{id}."""
    b = bridge_of(request)
    b.require_recorder()
    return b.jobs.start("protect", lambda job: svc.protect_titles(b, job, req.ids, req.protected), total=len(req.ids),
                        result={"changed": [], "skipped": [], "protected": req.protected}).to_dict()


@router.post("/titles/duplicates", response_model=S.Job, status_code=202)
async def titles_duplicates(request: Request):
    """Start looking for recordings that are copies of one broadcast; poll GET /jobs/{id} for the sets."""
    b = bridge_of(request)
    b.require_recorder()
    return b.jobs.start("duplicates", lambda job: svc.scan_duplicates(b, job), result={"sets": []}).to_dict()


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

@router.get("/recorder/playback", response_model=S.PlaybackStatus)
async def playback_status(request: Request):
    """What the recorder is playing on the TV connected to it."""
    rec = bridge_of(request).require_recorder()
    async with rec.lock:
        return _playback(await rec.xsrs.play_status())

@router.post("/recorder/playback", response_model=S.PlaybackStatus)
async def playback_control(request: Request, req: S.PlaybackControl):
    """Pause, resume or stop the recorder's own playback (`resume` only while paused)."""
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
        raise HTTPException(502, e.explanation)

@router.post("/titles/{title_id}/play", response_model=S.PlaybackStatus)
async def title_play(request: Request, title_id: str, position_sec: int = Query(0, ge=0)):
    """Start playing a recorded title on the TV connected to the recorder."""
    b = bridge_of(request)
    rec = b.require_recorder()
    if session.mac(b) and not await session.reachable(b) and not await session.wake(b):
        raise HTTPException(503, "the recorder does not answer, even after Wake-on-LAN")
    try:
        async with rec.lock:
            await _ensure_on(rec)
            await rec.xsrs.play_control(title_id, "play", position_sec)
            await asyncio.sleep(2)
            return _playback(await rec.xsrs.play_status())
    except XsrsError as e:
        raise HTTPException(404 if e.code in ("701", "803") else 502, e.explanation)

@router.patch("/titles/{title_id}", response_model=S.TitleFlags)
async def title_update(request: Request, title_id: str, req: S.TitleUpdate):
    """Protect / unprotect a recording, clear its NEW mark, or rename it."""
    rec = bridge_of(request).require_recorder()
    if req.protected is None and req.is_new is None and req.title is None:
        raise HTTPException(422, "nothing to change")
    el = build_title_update_elements(title_id, title=req.title, protected=req.protected, is_new=req.is_new)
    try:
        async with rec.lock:
            await rec.xsrs.update_title(el)
    except XsrsError as e:
        raise HTTPException(404 if e.code in ("701", "803") else 502, e.explanation)
    svc.forget_titles(bridge_of(request))
    return S.TitleFlags(id=title_id, protected=req.protected, is_new=req.is_new, title=req.title)

@router.delete("/titles/{title_id}", status_code=204)
async def title_delete(request: Request, title_id: str):
    """Delete a recording. This is final; the recorder refuses protected titles and ones being recorded."""
    b = bridge_of(request)
    rec = b.require_recorder()
    # A recording in progress is refused with a bare HTTP 500 and no error code, which tells a client
    # nothing. The list is already in hand, so say it here instead.
    known = {t.id: t for t in await svc.all_titles(b)}
    if title_id in known and known[title_id].recording:
        raise HTTPException(409, "録画中のため削除できません")
    try:
        async with rec.lock:
            # the recorder answers success for ids it does not know, so make sure the title exists first
            await rec.xsrs.title_detail(title_id)
            await rec.xsrs.delete_title(title_id)
    except XsrsError as e:
        raise HTTPException(404 if e.code in ("701", "803", "820") else 502, e.explanation)
    svc.forget_titles(bridge_of(request))

@router.get("/titles/{title_id}", response_model=S.TitleDetail)
async def title_detail(request: Request, title_id: str):
    """The programme text of one recording (summary and detail paragraphs)."""
    rec = bridge_of(request).require_recorder()
    try:
        async with rec.lock:
            detail = await rec.xsrs.title_detail(title_id)
    except XsrsError as e:
        raise HTTPException(404 if e.code in ("701", "803", "820") else 502, e.explanation)
    return S.TitleDetail(id=title_id, summary=detail["summary"], details=detail["details"])
