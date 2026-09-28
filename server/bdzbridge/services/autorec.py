"""Keyword auto-reservation.

After every EPG refresh (and on demand) the enabled rules are matched against the cached guide; every new match
that starts in the future is reserved on the recorder, unless the recorder reports a conflict. Each program is
tried once per rule (the outcome is kept in the auto_log table) -- unless the recorder was too busy to answer, which
decides nothing -- and one notification summarises a pass.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta

from ..recorder import codes
from ..recorder.epg import JST
from ..recorder.xsrs import XsrsError, build_create_elements
from ..store import ProgramRow

log = logging.getLogger("bdzbridge.autorec")


def _line(p: ProgramRow, note: str = "") -> str:
    return f"{p.start.strftime('%m/%d %H:%M')} {p.service_name or p.bt} {p.title}" + (f"（{note}）" if note else "")


async def run_rules(bridge, now: datetime | None = None) -> dict:
    """One pass over all enabled rules. Returns counts; sends one notification when anything happened."""
    store, rec = bridge.store, bridge.recorder
    rules = [r for r in store.rules() if r["enabled"]]
    result: dict = {"rules": len(rules), "checked": 0, "reserved": 0, "conflicts": 0, "errors": 0, "notified": []}
    if rec is None or not rules:
        return result
    now = now or datetime.now(JST)
    async with rec.lock:
        existing = await rec.xsrs.list_reservations()
    reserved = {(codes.BROADCASTING_BY_CODE.get(r.broadcasting_type), r.service_id, r.event_id)
                for r in existing if r.event_id is not None}
    lines: dict[str, list[str]] = {"reserved": [], "conflict": [], "error": []}
    for rule in rules:
        for p in store.rule_matches(rule, since=now + timedelta(minutes=1)):
            key = (p.bt, p.service_id, p.event_id)
            result["checked"] += 1
            if key in reserved or store.auto_logged(rule["id"], *key):
                continue
            el = build_create_elements(title=p.title, start=p.start, duration_sec=int((p.end - p.start).total_seconds()),
                                       repeat_code=codes.REPEAT["none"], broadcasting_type=codes.BROADCASTING[p.bt],
                                       service_id=p.service_id, quality_code=codes.QUALITY[rule["quality"]],
                                       event_id=p.event_id)
            try:
                async with rec.lock:
                    conflicts = await rec.xsrs.conflicts(el)
                    if conflicts:
                        status, message = "conflict", "、".join(c.title for c in conflicts)
                    else:
                        await rec.xsrs.create_reservation(el)
                        status, message = "reserved", ""
            except XsrsError as e:
                if e.busy:
                    # nothing was decided about this programme, so it is not logged, and the next pass asks again
                    log.warning("rule %s: recorder busy, %s left for the next pass", rule["id"], p.title)
                    continue
                status, message = "error", str(e)
            store.auto_log_add(rule["id"], p, status, message)
            if status == "reserved":
                reserved.add(key)
                result["reserved"] += 1
                lines["reserved"].append(f"{_line(p)}  ←「{rule['query']}」")
            elif status == "conflict":
                result["conflicts"] += 1
                lines["conflict"].append(_line(p, "重複: " + message))
            else:
                result["errors"] += 1
                lines["error"].append(_line(p, message))
            log.info("rule %s %s: %s", rule["id"], status, p.title)
    if any(lines.values()):
        parts = []
        if lines["reserved"]:
            parts.append("自動予約しました:\n" + "\n".join(lines["reserved"]))
        if lines["conflict"]:
            parts.append("重複のため予約していません:\n" + "\n".join(lines["conflict"]))
        if lines["error"]:
            parts.append("予約に失敗しました:\n" + "\n".join(lines["error"]))
        subject = f"[bdzbridge] 自動予約 {result['reserved']} 件"
        if result["conflicts"]:
            subject += f"、重複 {result['conflicts']} 件"
        if result["errors"]:
            subject += f"、失敗 {result['errors']} 件"
        result["notified"] = await bridge.notifier.send(subject, "\n\n".join(parts) + "\n")
    result["at"] = datetime.now(JST).isoformat(timespec="seconds")
    return result
