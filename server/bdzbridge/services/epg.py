"""The guide cache: refresh from the recorder, then let the rules and the monitor look at the new data."""
from __future__ import annotations

import asyncio
import logging

import httpx
from fastapi import HTTPException

from ..recorder import codes
from . import session
from .autorec import run_rules
from .monitor import run_checks

log = logging.getLogger("bdzbridge.epg")

NO_ANSWER = "the recorder does not answer, even after Wake-on-LAN"
# A guide file answered with an HTTP error is not a fault: the recorder has not made it yet, after a restart or a
# night off the network, and it comes back within hours (docs/epg-format.md). The same for every type, so said once.
FILE_NOT_MADE = "レコーダーの番組表ファイルがまだできていません。ふつうは数時間から一晩で作り直され、取得できるようになります。"


async def _awake(bridge) -> bool:
    """The recorder leaves the network after a while in standby, and the refresh that finds it gone is mostly
    the scheduled one, which nobody is watching. So it is woken first, as for playback, and then looked for
    elsewhere, as a lease may have moved it. Without a MAC there is nothing to send, and when it is not found either
    the refresh goes ahead and fails type by type as it did before."""
    if await session.reachable(bridge):
        return True
    if session.mac(bridge) and await session.wake(bridge):
        return True
    return await session.find_moved(bridge) or not session.mac(bridge)


async def refresh_epg(bridge) -> dict:
    if bridge.require_recorder().info is not None and not bridge.recorder.info.epg_capable:
        bridge.last_error = None
        return {"note": "this recorder does not provide an EPG (EPG_CAP is 00)", "epg_capable": False}
    async with bridge.refresh_lock:
        if not await _awake(bridge):
            bridge.last_error = NO_ANSWER
            raise HTTPException(503, NO_ANSWER)
        recorder = bridge.recorder  # a recorder that moved has a new client
        result = {}
        # the types that failed stay in last_error, for the settings screen, until a refresh has none
        errors: list[str] = []
        for bt in codes.EPG_FILES:
            try:
                services = await recorder.fetch_epg(bt)
            except httpx.HTTPStatusError as e:  # keep serving the cache
                log.warning("EPG %s fetch failed: %s", bt, e)
                errors.append(FILE_NOT_MADE)
                result[bt] = {"error": FILE_NOT_MADE}
                continue
            except httpx.TransportError as e:  # the recorder has gone: the next type would only wait for it too
                log.warning("EPG %s fetch got no answer: %s", bt, e)
                errors.append(f"{bt}: {e}")
                result[bt] = {"error": str(e)}
                break
            except Exception as e:
                log.warning("EPG %s fetch failed: %s", bt, e)
                errors.append(f"{bt}: {e}")
                result[bt] = {"error": str(e)}
                continue
            if services is None:
                result[bt] = {"programs": 0, "channels": 0, "note": "no channels"}
                continue
            n = await asyncio.to_thread(bridge.store.replace_services, bt, services)
            result[bt] = {"programs": n, "channels": len(services)}
            try:
                logos = await recorder.fetch_logos(bt)
            except Exception as e:  # logos are decoration; keep whatever is cached
                log.warning("logo %s fetch failed: %s", bt, e)
                logos = None
            if logos is not None:
                await asyncio.to_thread(bridge.store.replace_logos, bt, logos)
                result[bt]["logos"] = len(logos)
        bridge.last_error = "; ".join(dict.fromkeys(errors)) or None
    if any("programs" in v and v["programs"] for v in result.values()):
        try:
            bridge.last_autorec = await run_rules(bridge, bridge.clock())
            result["auto"] = bridge.last_autorec
        except Exception as e:
            log.warning("auto-reservation failed: %s", e)
        try:
            result["monitor"] = await run_checks(bridge)
        except Exception as e:
            log.warning("monitor failed: %s", e)
    return result


async def refresh_loop(bridge) -> None:
    first = bridge.settings.epg_refresh_on_start
    while True:
        if bridge.configured and first:
            try:
                await refresh_epg(bridge)
            except Exception as e:
                log.warning("EPG refresh failed: %s", e)
        first = True
        await asyncio.sleep(bridge.settings.epg_refresh_hours * 3600 if bridge.configured else 30)
