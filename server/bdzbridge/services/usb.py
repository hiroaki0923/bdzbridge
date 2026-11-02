"""The disk in the recorder's USB slot: what the recorder says of it now, and the disk kept between readings."""
from __future__ import annotations

import dataclasses
import json
import logging
import time

import httpx

from ..recorder.xsrs import Disk, XsrsError

log = logging.getLogger("bdzbridge.usb")

KNOWN = "usb_disk"
# Right after a waking the recorder answers the slot as if nothing were in it, and that answer is the same one an
# unplugged disk gets. It answered the disk five seconds later when timed; thirty leaves room for a slower disk.
SETTLE_SECONDS = 30


def known(bridge) -> Disk | None:
    text = bridge.store.get_meta(KNOWN)
    return Disk(**json.loads(text)) if text else None


async def read(bridge) -> tuple[Disk | None, bool]:
    """The disk in the slot, and whether the recorder has just said so; False hands back the disk last known. Silence
    and a recorder busy with someone else say nothing of the slot. One answer of no disk is not believed while a disk
    is known: it is forgotten when a reading SETTLE_SECONDS later says the same. A refusal is no disk."""
    rec, store = bridge.recorder, bridge.store
    try:
        async with rec.lock:
            disk = await rec.xsrs.usb_disk()
    except XsrsError as e:
        if e.busy:
            return known(bridge), False
        log.debug("the USB slot refused: %s", e)
        disk = None
    except httpx.HTTPError as e:
        log.debug("the USB slot did not answer: %s", e)
        return known(bridge), False
    if disk is not None:
        bridge.usb_none_since = None
        store.set_meta(KNOWN, json.dumps(dataclasses.asdict(disk), ensure_ascii=False))
        return disk, True
    last = known(bridge)
    if last is None:
        return None, True
    now = time.monotonic()
    if bridge.usb_none_since is None:
        bridge.usb_none_since = now
    if now - bridge.usb_none_since < SETTLE_SECONDS:
        return last, False
    bridge.usb_none_since = None
    store.delete_meta(KNOWN)
    return None, True
