"""Reservations on the recorder."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request

from ...recorder import codes
from ...recorder.epg import JST
from ...recorder.xsrs import (
    XsrsError,
    build_create_elements,
    build_update_elements,
)
from ...state import Bridge
from .. import schemas as S
from ..deps import auth, bridge_of
from ..serializers import reservation_out

router = APIRouter(prefix="/api/v1", tags=["reservations"], dependencies=[Depends(auth)])


@router.get("/reservations", response_model=list[S.Reservation])
async def reservations(request: Request):
    """Every reservation on the recorder, with the programme's genres when the guide still has it."""
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

@router.post("/reservations/check", response_model=S.ConflictReport)
async def reservation_check(request: Request, req: S.ReservationCreate):
    """Ask the recorder which existing reservations a new one would conflict with, without creating it."""
    b = bridge_of(request)
    rec = b.require_recorder()
    el, _ = _elements(b, req)
    try:
        async with rec.lock:
            conflicts = await rec.xsrs.conflicts(el)
    except XsrsError as e:
        raise HTTPException(502, str(e))
    return S.ConflictReport(conflicts=[reservation_out(c, b.store) for c in conflicts], ok=not conflicts)

@router.post("/reservations", response_model=S.ReservationCreated, status_code=201)
async def reservation_create(request: Request, req: S.ReservationCreate):
    """Create a reservation. With `event_id` the recorder follows schedule changes and uses its own title; without it give `start`, `duration_sec` and `title`. Answers 409 with the conflicts unless `force` is set."""
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

@router.patch("/reservations/{reservation_id}", response_model=S.Reservation)
async def reservation_update(request: Request, reservation_id: str, req: S.ReservationUpdate):
    """Change quality or repeat (and, for time-based reservations, title, start and duration)."""
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

@router.delete("/reservations/{reservation_id}", status_code=204)
async def reservation_delete(request: Request, reservation_id: str):
    """Delete a reservation."""
    rec = bridge_of(request).require_recorder()
    try:
        async with rec.lock:
            await rec.xsrs.delete_reservation(reservation_id)
    except XsrsError as e:
        raise HTTPException(502 if e.code not in ("701", "801") else 404, str(e))

# --- keyword auto-reservation ---
