"""Recorder selection, status, power, defaults, EPG refresh."""
from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, Depends, HTTPException, Request

from ...recorder import codes
from ...state import Bridge
from .. import schemas as S
from ..deps import auth, bridge_of

log = logging.getLogger("bdzbridge")
router = APIRouter(prefix="/api/v1", dependencies=[Depends(auth)])


@router.get("/recorders/discover", response_model=list[S.RecorderCandidate])
async def recorders_discover(request: Request):
    b = bridge_of(request)
    return [S.RecorderCandidate(**c.__dict__, selected=bool(b.recorder and b.recorder.host == c.host))
            for c in await b.discover()]

@router.put("/recorder", response_model=S.RecorderStatus)
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

@router.get("/recorder", response_model=S.RecorderStatus)
async def recorder_status(request: Request):
    b = bridge_of(request)
    epg = b.store.summary()
    epg["last_error"] = b.last_error
    if b.recorder is None:
        return S.RecorderStatus(configured=False, host=b.store.get_meta("recorder_host"), epg=epg)
    reachable = await b.reachable()
    if not reachable:
        return S.RecorderStatus(configured=True, host=b.recorder.host, reachable=False, mac=b.mac, epg=epg,
                                friendly_name=b.store.get_meta("recorder_name"), udn=b.store.get_meta("recorder_udn"))
    info = b.recorder.info or await b.recorder.discover()
    fw = power = play = storage = None
    try:
        async with b.recorder.lock:
            st = await b.recorder.xsrs.play_status()
            fw = await b.recorder.xsrs.firmware_version()
            try:
                storage = S.Storage(**await b.recorder.xsrs.record_destination_info())
            except Exception as e:  # not every model has the DLNA record-destination extension
                log.debug("no capacity info: %s", e)
        power, play = st.get("powerstatus"), st.get("playstatus")
    except Exception as e:
        log.warning("status query failed: %s", e)
    return S.RecorderStatus(configured=True, host=info.host, friendly_name=info.friendly_name, model=info.model,
                            product=info.product, epg_capable=info.epg_capable, udn=info.udn, firmware=fw, storage=storage,
                            power=power, play=play, epg=epg, reachable=True, mac=b.mac)

@router.post("/recorder/wake")
async def recorder_wake(request: Request):
    """Wake-on-LAN for a recorder that has dropped off the network."""
    b = bridge_of(request)
    return {"awake": await b.wake(), "mac": b.mac}

@router.post("/recorder/power")
async def recorder_power(request: Request):
    b = bridge_of(request)
    rec = b.require_recorder()
    if b.mac and not await b.reachable() and not await b.wake():
        raise HTTPException(503, "the recorder does not answer, even after Wake-on-LAN")
    async with rec.lock:
        return {"power": await rec.xsrs.power_on()}

@router.get("/defaults", response_model=S.Defaults)
async def defaults(request: Request):
    s = bridge_of(request).settings
    return S.Defaults(quality=s.default_quality, repeat=s.default_repeat, qualities=codes.QUALITY_LABEL,
                      repeats=codes.REPEAT_LABEL, broadcastings=codes.BROADCASTING_LABEL, genres=codes.GENRE_LABEL)

@router.post("/epg/refresh")
async def epg_refresh(request: Request):
    return await bridge_of(request).refresh_epg()
