"""Channels (with the user's visibility and order) and the programme guide."""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from ...recorder.epg import JST
from .. import schemas as S
from ..deps import auth, bridge_of
from ..serializers import channel_out, program_out

router = APIRouter(prefix="/api/v1", dependencies=[Depends(auth)])


@router.get("/channels", response_model=list[S.Channel])
async def channels(request: Request, broadcasting: S.Broadcasting | None = None,
                   include_hidden: bool = Query(False, description="also the channels the user has hidden")):
    return [channel_out(c) for c in bridge_of(request).store.channels(broadcasting, include_hidden)]

@router.put("/channels/{broadcasting}/prefs", response_model=list[S.Channel])
async def channel_prefs(request: Request, broadcasting: S.Broadcasting, req: S.ChannelPrefs):
    """Hide channels and/or reorder them; returns every channel of that type, hidden ones included."""
    store = bridge_of(request).store
    store.set_channel_prefs(broadcasting, order=req.order, hidden=req.hidden)
    return [channel_out(c) for c in store.channels(broadcasting, include_hidden=True)]

@router.get("/programs", response_model=list[S.Program])
async def programs(request: Request, broadcasting: S.Broadcasting | None = None, service_id: int | None = None,
                   date: str | None = Query(None, description="YYYY-MM-DD; TV day 04:00-04:00 JST"),
                   since: datetime | None = None, until: datetime | None = None, q: str | None = None,
                   compact: bool = Query(False, description="omit description/extended (for the grid view)"),
                   include_hidden: bool = Query(False, description="include programs of channels the user has hidden"),
                   limit: int = Query(500, le=5000), offset: int = 0):
    store = bridge_of(request).store
    if date:
        since, until = store.day_range(datetime.fromisoformat(date).replace(tzinfo=JST))
    rows = store.programs(bt=broadcasting, service_id=service_id, since=since, until=until, query=q,
                          include_hidden=include_hidden, limit=limit, offset=offset)
    return [program_out(p, compact) for p in rows]

@router.get("/programs/now", response_model=list[S.Program])
async def programs_now(request: Request, broadcasting: S.Broadcasting = "td"):
    return [program_out(p) for p in bridge_of(request).store.now_on_air(broadcasting)]

@router.get("/programs/{broadcasting}/{service_id}/{event_id}", response_model=S.Program)
async def program(request: Request, broadcasting: S.Broadcasting, service_id: int, event_id: int):
    p = bridge_of(request).store.program(broadcasting, service_id, event_id)
    if not p:
        raise HTTPException(404, "program not found")
    return program_out(p)
