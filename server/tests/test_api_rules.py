from __future__ import annotations

from datetime import datetime

from fastapi.testclient import TestClient

from bdzbridge.api.app import create_app
from bdzbridge.config import Settings
from bdzbridge.recorder import wol
from bdzbridge.recorder.epg import JST
from bdzbridge.recorder.xsrs import Reservation
from bdzbridge.state import Bridge
from bdzbridge.store import Store
from tests.conftest import (
    TOKEN,
    FakeNotifier,
    FakeRecorder,
    H,
    autorec_client,
    free_space,
)


def test_rules_reserve_matching_programs_once(client):
    c = autorec_client(client)
    r = c.post("/api/v1/rules", headers=H, json={"query": "sample"}, params={"run": "true"})
    assert r.status_code == 201 and r.json()["quality"] == "LSR" and r.json()["title_only"] is True
    rid = r.json()["id"]
    assert [m["event_id"] for m in c.get(f"/api/v1/rules/{rid}/matches", headers=H).json()] == [14794]
    res = [x for x in c.get("/api/v1/reservations", headers=H).json() if x["event_id"] == 14794]
    assert len(res) == 1 and res[0]["title"] == "日曜劇場「ＳＡＭＰＬＥ」" and res[0]["quality"] == "LSR"
    logs = c.get("/api/v1/rules/log", headers=H).json()
    assert [(x["status"], x["event_id"], x["rule_query"]) for x in logs] == [("reserved", 14794, "sample")]
    sent = c.bridge.notifier.sent
    assert len(sent) == 1 and sent[0][0] == "[bdzbridge] 自動予約 1 件" and "ＳＡＭＰＬＥ" in sent[0][1] and "「ＳＡＭＰＬＥ」" in sent[0][1]
    # a second pass finds nothing new and stays quiet
    run = c.post("/api/v1/rules/run", headers=H).json()
    assert (run["checked"], run["reserved"], run["notified"]) == (1, 0, []) and len(sent) == 1
    # disabled rules are skipped; deleting removes the rule and its log
    assert c.patch(f"/api/v1/rules/{rid}", headers=H, json={"enabled": False}).json()["enabled"] is False
    assert c.post("/api/v1/rules/run", headers=H).json()["rules"] == 0
    assert c.delete(f"/api/v1/rules/{rid}", headers=H).status_code == 204
    assert c.get("/api/v1/rules", headers=H).json() == [] and c.get("/api/v1/rules/log", headers=H).json() == []
    assert c.delete(f"/api/v1/rules/{rid}", headers=H).status_code == 404

def test_rules_report_conflicts_without_reserving(client):
    c = autorec_client(client)
    other = Reservation("0x9", "別の予約", datetime(2026, 9, 14, 6, 0, tzinfo=JST), 900, "1", 2, 1040, None, 240, False, False, "HDD", None, "2000")
    c.bridge.recorder.xsrs.conflict_with = [other]
    c.post("/api/v1/rules", headers=H, json={"query": "あさのサンプル", "quality": "DR"})
    run = c.post("/api/v1/rules/run", headers=H).json()
    assert (run["reserved"], run["conflicts"], run["notified"]) == (0, 1, ["email"])
    assert not [x for x in c.get("/api/v1/reservations", headers=H).json() if x["event_id"] == 14793]
    log = c.get("/api/v1/rules/log", headers=H).json()[0]
    assert log["status"] == "conflict" and log["message"] == "別の予約"
    assert "重複" in c.bridge.notifier.sent[0][0]

def test_rules_run_after_epg_refresh(client):
    c = autorec_client(client)
    c.post("/api/v1/rules", headers=H, json={"query": "ニュース", "title_only": False})
    res = c.post("/api/v1/epg/refresh", headers=H).json()
    assert res["auto"]["reserved"] == 1 and c.bridge.last_autorec["reserved"] == 1
    assert c.get("/api/v1/notify", headers=H).json()["configured"] is True

def test_watch_state_and_monitor(client):
    ts = {t["id"]: t for t in client.get("/api/v1/titles", headers=H).json()}
    assert ts["0x0000010000034d78"]["watch_state"] == "unwatched"
    assert ts["0x0000010000034d79"]["watch_state"] == "partway" and ts["0x0000010000034d79"]["resume_sec"] == 754
    assert ts["0x0000010000034d7a"]["watch_state"] == "watched"
    c = autorec_client(client)
    r = c.post("/api/v1/monitor/run", headers=H).json()  # the fake recorder has 8.5 GB free
    assert r["low_space"] is True and r["free_gb"] == 8.6 and r["notified"] == ["email"]
    assert "HDD 残量警告" in c.bridge.notifier.sent[-1][0]
    assert c.post("/api/v1/monitor/run", headers=H).json()["low_space"] is False and len(c.bridge.notifier.sent) == 1
    # a reservation the recorder flags as conflicting is reported once
    other = Reservation("0x7", "重なる予約", datetime(2026, 9, 14, 20, 0, tzinfo=JST), 900, "1", 2, 1040, None, 240, False, True, "HDD", None, "2000")
    c.bridge.recorder.xsrs.reservations.append(other)
    r = c.post("/api/v1/monitor/run", headers=H).json()
    assert r["new_conflicts"] == ["0x7"] and "予約の重複 1 件" in c.bridge.notifier.sent[-1][0] and "重なる予約" in c.bridge.notifier.sent[-1][1]
    assert c.post("/api/v1/monitor/run", headers=H).json()["new_conflicts"] == [] and len(c.bridge.notifier.sent) == 2

def test_monitor_warns_again_only_after_space_recovers(client):
    c = autorec_client(client)
    x = c.bridge.recorder.xsrs
    assert c.post("/api/v1/monitor/run", headers=H).json()["low_space"] is True
    x.record_destination_info = lambda destination="HDD": free_space(55e9)  # above 50 but below the 60 GB re-arm line
    assert c.post("/api/v1/monitor/run", headers=H).json()["low_space"] is False
    x.record_destination_info = lambda destination="HDD": free_space(200e9)
    assert c.post("/api/v1/monitor/run", headers=H).json()["low_space"] is False  # recovered: warning re-armed
    x.record_destination_info = lambda destination="HDD": free_space(10e9)
    assert c.post("/api/v1/monitor/run", headers=H).json()["low_space"] is True
    assert len(c.bridge.notifier.sent) == 2

def test_monitor_free_space_check_can_be_disabled(tmp_path, monkeypatch):

    async def _reachable(host, port, timeout=2.0):
        return True

    monkeypatch.setattr(wol, "port_open", _reachable)
    settings = Settings(recorder_host="127.0.0.1", api_token=TOKEN, db_path=str(tmp_path / "m.sqlite3"), epg_refresh_on_start=False,
                        notify_free_gb=0)
    store = Store(settings.db_path)
    bridge = Bridge(settings, FakeRecorder(), store)
    bridge.notifier = FakeNotifier()
    with TestClient(create_app(settings, bridge)) as c:
        r = c.post("/api/v1/monitor/run", headers=H).json()
    assert r["free_gb"] is None and r["low_space"] is False and bridge.notifier.sent == []

def test_hidden_channels_are_skipped_by_rules(client):
    c = autorec_client(client)
    c.put("/api/v1/channels/td/prefs", headers=H, json={"hidden": [1024]})
    rid = c.post("/api/v1/rules", headers=H, json={"query": "sample"}).json()["id"]
    assert c.get(f"/api/v1/rules/{rid}/matches", headers=H).json() == []
    assert c.post("/api/v1/rules/run", headers=H).json()["reserved"] == 0
    c.put("/api/v1/channels/td/prefs", headers=H, json={"hidden": []})
    assert [m["event_id"] for m in c.get(f"/api/v1/rules/{rid}/matches", headers=H).json()] == [14794]

def test_rules_match_description_when_not_title_only(client):
    c = autorec_client(client)
    only = c.post("/api/v1/rules", headers=H, json={"query": "朝のニュース", "title_only": True}).json()
    wide = c.post("/api/v1/rules", headers=H, json={"query": "朝のニュース", "title_only": False}).json()
    assert c.get(f"/api/v1/rules/{only['id']}/matches", headers=H).json() == []
    assert [m["event_id"] for m in c.get(f"/api/v1/rules/{wide['id']}/matches", headers=H).json()] == [14792]


def test_recorder_rules_are_made_on_the_recorder_and_deleted_there(client):
    r = client.post("/api/v1/recorder-rules", headers=H,
                    json={"keywords": [" サンプル ", "テスト"], "excluded": ["ダミー"], "logic": "AND",
                          "genre_level1": 5, "genre_level2": 0, "time_scope": "NIGHT", "broadcasting_scope": "TRD", "quality": "XSR"})
    assert r.status_code == 201, r.text
    made = r.json()
    assert made["keywords"] == ["サンプル", "テスト"] and made["excluded"] == ["ダミー"]
    assert made["logic"] == "AND" and made["logic_label"] == "すべてのキーワードを含む"
    assert made["genres"][0] == {"level1": 5, "level2": 0, "label": "バラエティ", "label2": "クイズ"}
    assert made["time_scope_label"] == "夜" and made["broadcasting_scope_label"] == "地上放送"
    assert made["quality"] == "XSR" and made["quality_4k"] is None and made["destination"] == "HDD"
    assert made["name"] == "サンプル/テスト"  # the fake composes one the way the recorder does
    listed = client.get("/api/v1/recorder-rules", headers=H).json()
    assert [x["id"] for x in listed] == [made["id"]]
    assert client.delete(f"/api/v1/recorder-rules/{made['id']}", headers=H).status_code == 204
    assert client.get("/api/v1/recorder-rules", headers=H).json() == []


def test_recorder_rule_defaults_and_limits(client):
    r = client.post("/api/v1/recorder-rules", headers=H, json={"keywords": ["サンプル"]})
    assert r.status_code == 201, r.text
    made = r.json()
    assert made["logic"] == "OR" and made["time_scope"] == "ALL" and made["broadcasting_scope"] == "ALL"
    assert made["quality"] == "LSR" and made["genres"] == []   # the server's default quality
    assert made["quality_4k"] == "LSR"   # every wave, so the 4K ones too rather than the recorder's DR
    assert client.post("/api/v1/recorder-rules", headers=H, json={"keywords": []}).status_code == 422
    assert client.post("/api/v1/recorder-rules", headers=H, json={"keywords": [], "genre_level2": 0}).status_code == 422
    whole = client.post("/api/v1/recorder-rules", headers=H, json={"keywords": [], "genre_level1": 5, "time_scope": "MORNING",
                                                                  "broadcasting_scope": "BSD"}).json()
    assert whole["genres"] == [{"level1": 5, "level2": None, "label": "バラエティ", "label2": None}]
    assert whole["keywords"] == []
    assert whole["time_scope_label"] == "朝" and whole["broadcasting_scope_label"] == "BS放送"
    assert client.post("/api/v1/recorder-rules", headers=H, json={"keywords": ["a"] * 6}).status_code == 422
    assert client.post("/api/v1/recorder-rules", headers=H, json={"keywords": ["a"], "excluded": ["x", "y", "z"]}).status_code == 422
    assert client.post("/api/v1/recorder-rules", headers=H, json={"keywords": ["a"], "logic": "XOR"}).status_code == 422
