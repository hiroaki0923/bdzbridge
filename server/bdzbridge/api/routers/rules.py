"""Keyword auto-reservation rules, the monitor, and notifications."""
from __future__ import annotations

from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from ...services.autorec import run_rules
from ...services.monitor import run_checks
from .. import schemas as S
from ..deps import auth, bridge_of
from ..serializers import log_out, program_out, rule_out

router = APIRouter(prefix="/api/v1", dependencies=[Depends(auth)])


@router.get("/rules", response_model=list[S.Rule])
async def rules(request: Request):
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
    b = bridge_of(request)
    r = b.store.update_rule(rule_id, enabled=req.enabled, quality=req.quality, title_only=req.title_only)
    if r is None:
        raise HTTPException(404, "rule not found")
    return rule_out(b, r)

@router.delete("/rules/{rule_id}", status_code=204)
async def rule_delete(request: Request, rule_id: int):
    if not bridge_of(request).store.delete_rule(rule_id):
        raise HTTPException(404, "rule not found")

@router.post("/monitor/run", response_model=S.MonitorResult)
async def monitor_run(request: Request):
    """Check free space and conflicting reservations now (normally runs after every EPG refresh)."""
    b = bridge_of(request)
    b.require_recorder()
    return await run_checks(b)

@router.get("/notify", response_model=S.NotifyStatus)
async def notify_status(request: Request):
    n = bridge_of(request).notifier
    return S.NotifyStatus(configured=n.configured, email=n.email_configured, webhook=n.webhook_configured,
                          to=n.s.notify_to or None, free_gb=n.s.notify_free_gb)

@router.post("/notify/test", response_model=S.NotifyStatus)
async def notify_test(request: Request):
    n = bridge_of(request).notifier
    if not n.configured:
        raise HTTPException(400, "no notification channel configured (BDZBRIDGE_SMTP_* / BDZBRIDGE_NOTIFY_*)")
    sent = await n.send("[bdzbridge] テスト通知", "bdzbridge からのテスト通知です。自動予約の結果はこの宛先に届きます。\n")
    if not sent:
        raise HTTPException(502, "sending failed; see the server log")
    return S.NotifyStatus(configured=True, email=n.email_configured, webhook=n.webhook_configured, to=n.s.notify_to or None, sent=sent)
