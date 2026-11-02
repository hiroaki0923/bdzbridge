"""Periodic checks reported through the notifier: disks running low, reservations the recorder flags as conflicting.

Runs after every EPG refresh (and on demand). Each condition is reported once: the low-space warning re-arms after
free space climbs back 20 % above the threshold, a conflict is reported when its reservation is first seen conflicting.
The USB disk's warning remembers which disk it was about, so that another disk put in the slot is warned about too.
"""
from __future__ import annotations

import json
import logging

from ..recorder.xsrs import Reservation
from . import usb

log = logging.getLogger("bdzbridge.monitor")

ADVICE = "古い録画を整理するか、録画モードを見直してください。"
WARNED_USB = "warned_low_usb"


def _conflict_key(r: Reservation) -> str:
    """A reservation by what it is rather than by its id. The recorder renumbers the reservations its own automatic
    recording made, the whole block at once (docs/xsrs-api.md), so a conflict remembered by id came back as a new one
    each time. No two reservations share a channel and a start."""
    return f"{r.broadcasting_type}:{r.service_id}:{int(r.start.timestamp())}"


async def _usb_space(bridge, result: dict) -> list[str]:
    """The USB disk's room, only from what the recorder has just said of a disk that takes recordings."""
    store, line = bridge.store, bridge.settings.notify_free_gb
    disk, answered = await usb.read(bridge)
    if not answered or disk is None or not disk.takes_recordings or disk.free_bytes is None:
        return []
    free_gb = disk.free_bytes / 1e9
    result["usb_free_gb"] = round(free_gb, 1)
    warned = store.get_meta(WARNED_USB) == disk.identity
    if free_gb < line and not warned:
        store.set_meta(WARNED_USB, disk.identity)
        result["low_space_usb"] = True
        return [f"{disk.name or 'USB HDD'} の残りが {free_gb:.1f} GB です（{line:g} GB 未満）。{ADVICE}"]
    if warned and free_gb >= line * 1.2:
        store.delete_meta(WARNED_USB)
    return []


async def run_checks(bridge) -> dict:
    rec, store, s = bridge.recorder, bridge.store, bridge.settings
    result: dict = {"free_gb": None, "low_space": False, "usb_free_gb": None, "low_space_usb": False,
                    "new_conflicts": [], "notified": []}
    if rec is None:
        return result
    parts: list[str] = []
    if s.notify_free_gb > 0:
        try:
            async with rec.lock:
                info = await rec.xsrs.record_destination_info()
            free_gb = info["free_bytes"] / 1e9
            result["free_gb"] = round(free_gb, 1)
            warned = store.get_meta("warned_low_space") == "1"
            if free_gb < s.notify_free_gb and not warned:
                parts.append(f"HDD の残りが {free_gb:.1f} GB です（{s.notify_free_gb:g} GB 未満）。{ADVICE}")
                store.set_meta("warned_low_space", "1")
                result["low_space"] = True
            elif warned and free_gb >= s.notify_free_gb * 1.2:
                store.set_meta("warned_low_space", "0")
        except Exception as e:
            log.warning("free-space check failed: %s", e)
        try:
            parts += await _usb_space(bridge, result)
        except Exception as e:
            log.warning("USB free-space check failed: %s", e)
    try:
        async with rec.lock:
            items = await rec.xsrs.list_reservations()
        # a list saved before the keys holds ids, which still count for the pass that replaces it
        seen = set(json.loads(store.get_meta("notified_conflicts") or "[]"))
        conflicts = [r for r in items if r.conflict]
        new = [r for r in conflicts if _conflict_key(r) not in seen and r.id not in seen]
        if new:
            parts.append("重複している予約（このままだと録画されない可能性があります）:\n"
                         + "\n".join(f"{r.start.strftime('%m/%d %H:%M')} {r.title}" for r in new))
            result["new_conflicts"] = [r.id for r in new]
        store.set_meta("notified_conflicts", json.dumps([_conflict_key(r) for r in conflicts]))
    except Exception as e:
        log.warning("conflict check failed: %s", e)
    if parts:
        subject = "[bdzbridge] " + "、".join(
            [t for t, on in (("HDD 残量警告", result["low_space"]), ("USB HDD 残量警告", result["low_space_usb"]), (f"予約の重複 {len(result['new_conflicts'])} 件", result["new_conflicts"])) if on])
        result["notified"] = await bridge.notifier.send(subject, "\n\n".join(parts) + "\n")
    return result
