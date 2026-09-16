"""Keyword auto-reservation rules, the monitor, and notifications."""
from __future__ import annotations

from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from ...recorder import codes
from ...recorder.xsrs import XsrsError, build_recorder_rule_elements
from ...services.autorec import run_rules
from ...services.monitor import run_checks
from .. import schemas as S
from ..deps import auth, bridge_of
from ..serializers import log_out, program_out, recorder_rule_out, rule_out

router = APIRouter(prefix="/api/v1", tags=["rules"], dependencies=[Depends(auth)])


@router.get("/rules", response_model=list[S.Rule])
async def rules(request: Request):
    """The keyword auto-reservation rules."""
    b = bridge_of(request)
    return [rule_out(b, r) for r in b.store.rules()]

@router.post("/rules", response_model=S.Rule, status_code=201)
async def rule_create(request: Request, req: S.RuleCreate,
                      run: bool = Query(False, description="apply every rule right away (reserves on the recorder)")):
    b = bridge_of(request)
    r = b.store.add_rule(req.query, req.broadcasting, req.service_id, req.title_only, req.quality or b.settings.default_quality)
    if run and b.configured:
        b.last_autorec = await run_rules(b, b.clock())
    return rule_out(b, r)

@router.get("/rules/log", response_model=list[S.AutoLogEntry])
async def rules_log(request: Request, limit: int = Query(50, le=500)):
    return [log_out(r) for r in bridge_of(request).store.auto_log(limit)]

@router.post("/rules/run", response_model=S.AutoRunResult)
async def rules_run(request: Request):
    """Apply every enabled rule now (they also run after each guide refresh); reports what was reserved."""
    b = bridge_of(request)
    b.require_recorder()
    b.last_autorec = await run_rules(b, b.clock())
    return b.last_autorec

@router.get("/rules/{rule_id}/matches", response_model=list[S.Program])
async def rule_matches(request: Request, rule_id: int):
    """Upcoming programs the rule matches (reserved or not)."""
    b = bridge_of(request)
    r = b.store.rule(rule_id)
    if r is None:
        raise HTTPException(404, "rule not found")
    return [program_out(p, True) for p in b.store.rule_matches(r, since=b.clock() + timedelta(minutes=1))]

@router.patch("/rules/{rule_id}", response_model=S.Rule)
async def rule_update(request: Request, rule_id: int, req: S.RuleUpdate):
    """Enable or disable a rule, or change its quality or title-only matching."""
    b = bridge_of(request)
    r = b.store.update_rule(rule_id, enabled=req.enabled, quality=req.quality, title_only=req.title_only)
    if r is None:
        raise HTTPException(404, "rule not found")
    return rule_out(b, r)

@router.delete("/rules/{rule_id}", status_code=204)
async def rule_delete(request: Request, rule_id: int):
    """Delete a rule and its log."""
    if not bridge_of(request).store.delete_rule(rule_id):
        raise HTTPException(404, "rule not found")

# --- the recorder's own keyword conditions (おまかせ・まる録) ---
# Create and delete only. A condition the recorder lists is missing the channel narrowing its own screen can
# set, so writing one back would destroy that; and since the recorder renumbers a condition on every change,
# an update would keep nothing that a delete and a create do not.

@router.get("/recorder-rules", response_model=list[S.RecorderRule])
async def recorder_rules(request: Request):
    """The keyword conditions held by the recorder itself (おまかせ・まる録). These record without this server. The channel narrowing set on the recorder's screen is not reported."""
    b = bridge_of(request)
    rec = b.require_recorder()
    try:
        async with rec.lock:
            rules = await rec.xsrs.list_recorder_rules()
    except XsrsError as e:
        raise HTTPException(502, e.explanation)
    return [recorder_rule_out(r) for r in rules]

@router.post("/recorder-rules", response_model=S.RecorderRule, status_code=201)
async def recorder_rule_create(request: Request, req: S.RecorderRuleCreate):
    """Register a condition on the recorder itself. The recorder composes the name; the channel cannot be set this way."""
    b = bridge_of(request)
    rec = b.require_recorder()
    el = build_recorder_rule_elements(keywords=req.keywords, excluded=req.excluded, logic=req.logic,
                                      genre_code=req.genre_code, time_scope=req.time_scope,
                                      broadcasting_scope=req.broadcasting_scope,
                                      quality_code=codes.QUALITY[req.quality or b.settings.default_quality])
    try:
        async with rec.lock:
            new_id = await rec.xsrs.create_recorder_rule(el)
            rules = await rec.xsrs.list_recorder_rules()
    except XsrsError as e:
        raise HTTPException(502, e.explanation)
    made = next((r for r in rules if r.id == new_id), None)
    if made is None:
        raise HTTPException(502, f"recorder returned id {new_id} but it is not in the list")
    return recorder_rule_out(made)

@router.delete("/recorder-rules/{rule_id}", status_code=204)
async def recorder_rule_delete(request: Request, rule_id: str):
    """Remove a condition from the recorder, whoever made it. Ids change whenever the recorder's screen edits a condition, so read the list first."""
    b = bridge_of(request)
    rec = b.require_recorder()
    try:
        async with rec.lock:
            await rec.xsrs.delete_recorder_rule(rule_id)
    except XsrsError as e:
        raise HTTPException(502, e.explanation)


@router.post("/monitor/run", response_model=S.MonitorResult)
async def monitor_run(request: Request):
    """Check free space and conflicting reservations now (normally runs after every EPG refresh)."""
    b = bridge_of(request)
    b.require_recorder()
    return await run_checks(b)

@router.get("/notify", response_model=S.NotifyStatus)
async def notify_status(request: Request):
    """Which notification channels are configured (SMTP, webhook) and the free-space warning threshold."""
    n = bridge_of(request).notifier
    return S.NotifyStatus(configured=n.configured, email=n.email_configured, webhook=n.webhook_configured,
                          to=n.s.notify_to or None, free_gb=n.s.notify_free_gb)

@router.post("/notify/test", response_model=S.NotifyStatus)
async def notify_test(request: Request):
    """Send a test message through every configured channel."""
    n = bridge_of(request).notifier
    if not n.configured:
        raise HTTPException(400, "no notification channel configured (BDZBRIDGE_SMTP_* / BDZBRIDGE_NOTIFY_*)")
    sent = await n.send("[bdzbridge] テスト通知", "bdzbridge からのテスト通知です。自動予約の結果はこの宛先に届きます。\n")
    if not sent:
        raise HTTPException(502, "sending failed; see the server log")
    return S.NotifyStatus(configured=True, email=n.email_configured, webhook=n.webhook_configured, to=n.s.notify_to or None, sent=sent)
