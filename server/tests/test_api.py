from __future__ import annotations

import asyncio
import base64
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from bdzbridge.api.app import Bridge, create_app
from bdzbridge.config import Settings
from bdzbridge.recorder.epg import JST
from bdzbridge.recorder.logo import Logo, with_palette
from bdzbridge.recorder.xsrs import Reservation, parse_reservation
from bdzbridge.store import Store
from tests.conftest import make_services
from tests.test_logo import make_png

TOKEN = "t"
H = {"Authorization": f"Bearer {TOKEN}"}


class FakeXsrs:
    def __init__(self):
        self.reservations: list[Reservation] = []
        self.conflict_with: list[Reservation] = []
        self.created: list[str] = []

    async def list_reservations(self, count=200):
        return list(self.reservations)

    async def conflicts(self, elements):
        return list(self.conflict_with)

    async def create_reservation(self, elements):
        item = ET.fromstring(elements).find("{urn:schemas-xsrs-org:metadata-1-0/x_srs/}item")
        item.set("id", f"0x{len(self.created) + 1:016x}")
        r = parse_reservation(item)
        r.creator = "2200"
        self.reservations.append(r)
        self.created.append(elements)
        return r.id

    async def update_reservation(self, elements):
        item = ET.fromstring(elements).find("{urn:schemas-xsrs-org:metadata-1-0/x_srs/}item")
        r = parse_reservation(item)
        r.creator = "2200"
        self.reservations = [r if x.id == r.id else x for x in self.reservations]
        self.created.append(elements)

    async def delete_reservation(self, rid):
        self.reservations = [r for r in self.reservations if r.id != rid]

    def _titles(self):
        from bdzbridge.recorder.xsrs import RecordedTitle
        deleted = getattr(self, "deleted", set())
        extra = getattr(self, "extra_titles", [])
        all_ = extra + [RecordedTitle("0x0000010000034d78", "録画したドラマ", datetime(2026, 9, 13, 21, 0, tzinfo=JST), 4148, 2, 1048, 230,
                              False, True, "HDD", 4376, genre_code=48),
                RecordedTitle("0x0000010000034d79", "録画したドラマ　第２話[字]", datetime(2026, 9, 12, 21, 0, tzinfo=JST), 3600, 2, 1048, 230,
                              True, False, "HDD", 4000, genre_code=48, last_played=datetime(2026, 9, 13, 1, 0, tzinfo=JST), resume_sec=754),
                RecordedTitle("0x0000010000034d7a", "別の番組[字]", datetime(2026, 9, 11, 21, 0, tzinfo=JST), 1800, 2, 1024, 240,
                              False, False, "HDD", 900, genre_code=0),
                RecordedTitle("0x0000010000034d7b", "録画したドラマ[再]", datetime(2026, 9, 10, 15, 0, tzinfo=JST), 4150, 2, 1049, 230,
                              False, False, "HDD", 4300, genre_code=48, resume_sec=0)]
        return [t for t in all_ if t.id not in deleted]

    async def list_titles(self, count=100, start=0):
        return self._titles()[start:start + count]

    async def list_titles_all(self, page=200):
        return self._titles()

    async def title_detail(self, title_id):
        summaries = getattr(self, "summaries", {})
        return {"summary": summaries.get(title_id, "あらすじ"), "details": ["番組内容 本文"]}

    async def power_on(self):
        self.powered = getattr(self, "powered", 0) + 1
        return "PowerOn"

    def __init_playback__(self):
        pass

    async def play_status(self):
        st = getattr(self, "_play", None)
        return st or {"powerstatus": "PowerOn", "playstatus": "Stopped"}

    async def play_control(self, title_id, operation, position=0):
        self.plays = getattr(self, "plays", []) + [(title_id, operation, position)]
        if operation == "play":
            self._play = {"powerstatus": "PowerOn", "playstatus": "Playing", "item": title_id, "position": "7", "chapterNumber": "2"}
        elif operation == "pause":
            self._play = dict(self._play, playstatus="Paused" if self._play["playstatus"] == "Playing" else "Playing")
        else:
            self._play = {"powerstatus": "PowerOn", "playstatus": "Stopped"}

    async def firmware_version(self):
        return "35.003.1"

    async def delete_title(self, title_id):
        from bdzbridge.recorder.xsrs import XsrsError
        if title_id not in {t.id for t in self._titles()}:
            raise XsrsError("X_DeleteTitle", 500, "701")
        self.deleted = getattr(self, "deleted", set()) | {title_id}

    async def update_title(self, elements):
        item = ET.fromstring(elements).find("{urn:schemas-xsrs-org:metadata-1-0/x_srs/}item")
        self.title_updates = getattr(self, "title_updates", []) + [(item.get("id"), {c.tag.split("}")[-1]: c.text for c in item})]

    async def record_destination_info(self, destination="HDD"):
        return {"total_bytes": 4_294_967_296_000, "free_bytes": 8_556_380_160}


class FakeRecorder:
    def __init__(self):
        self.xsrs = FakeXsrs()
        self.lock = asyncio.Lock()
        self.info = None
        self.host = "127.0.0.1"

    async def discover(self):
        from bdzbridge.recorder.client import RecorderInfo
        self.info = RecorderInfo("127.0.0.1", "BDR - TEST", "BDZ-TEST", "BDZ-TEST", True, "uuid:x")
        return self.info

    async def fetch_epg(self, bt):
        return make_services() if bt == "td" else None

    async def fetch_logos(self, bt):
        return [Logo(11, 1024, with_palette(make_png()))] if bt == "td" else None


    async def close(self):
        pass


@pytest.fixture
def client(tmp_path, monkeypatch):
    from bdzbridge.api import app as appmod

    async def _reachable(host, port, timeout=2.0):  # nothing listens on 64220 in tests: pretend the recorder answers
        return True

    monkeypatch.setattr(appmod.wol, "port_open", _reachable)
    settings = Settings(recorder_host="127.0.0.1", api_token=TOKEN, db_path=str(tmp_path / "t.sqlite3"),
                       epg_refresh_on_start=False)
    store = Store(settings.db_path)
    store.replace_services("td", make_services())
    bridge = Bridge(settings, FakeRecorder(), store)
    app = create_app(settings, bridge)
    with TestClient(app) as c:
        c.bridge = bridge
        yield c


def test_auth_required(client):
    assert client.get("/api/v1/channels").status_code == 401
    assert client.get("/api/v1/channels", headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_channels_and_programs(client):
    chs = client.get("/api/v1/channels", headers=H).json()
    assert [c["service_id"] for c in chs] == [1024, 1025]
    ps = client.get("/api/v1/programs", headers=H, params={"broadcasting": "td", "service_id": 1024, "date": "2026-09-14"}).json()
    assert [p["event_id"] for p in ps] == [14792, 14793, 14794]  # the next-day program falls outside the 04:00-04:00 TV day
    assert ps[0]["genres"][0]["label"] == "ニュース／報道" and ps[0]["start"] == "2026-09-14T05:00:00+09:00"
    one = client.get("/api/v1/programs/td/1024/14792", headers=H).json()
    assert one["title"] == "サンプルニュース　あさの放送"
    q = client.get("/api/v1/programs", headers=H, params={"q": "あさのサンプル"}).json()
    assert [p["event_id"] for p in q] == [14793]


def test_reference_programs_resolve_to_parent(client):
    ps = client.get("/api/v1/programs", headers=H, params={"service_id": 1025}).json()
    assert ps == []  # references hidden by default
    row = client.bridge.store.programs(service_id=1025, include_references=True)[0]
    assert row.is_reference and row.title == "サンプルニュース　あさの放送"


def test_reservation_from_event_id(client):
    r = client.post("/api/v1/reservations", headers=H, json={"broadcasting": "td", "service_id": 1024, "event_id": 14792})
    assert r.status_code == 201, r.text
    body = r.json()["reservation"]
    assert body["title"] == "サンプルニュース　あさの放送" and body["duration_sec"] == 3600 and body["tracks_program"]
    assert body["quality"] == "LSR" and body["repeat"] == "none" and body["created_by_app"]
    xml = client.bridge.recorder.xsrs.created[0]
    assert ",,0x400,0x39c8" in xml and "<desiredQualityMode>240</desiredQualityMode>" in xml
    assert len(client.get("/api/v1/reservations", headers=H).json()) == 1
    assert client.delete(f"/api/v1/reservations/{body['id']}", headers=H).status_code == 204
    assert client.get("/api/v1/reservations", headers=H).json() == []


def test_reservation_time_based_and_conflict(client):
    fx = client.bridge.recorder.xsrs
    payload = {"broadcasting": "bs", "service_id": 101, "start": "2026-09-15T04:00:00+09:00", "duration_sec": 300,
               "title": "TEST", "quality": "SR", "repeat": "mon-fri"}
    fx.conflict_with = [Reservation("0x1", "既存", datetime(2026, 9, 15, 4, 0, tzinfo=JST), 600, "1", 3, 101, None, 230,
                                    False, False, "HDD", None, "2200")]
    chk = client.post("/api/v1/reservations/check", headers=H, json=payload).json()
    assert chk["ok"] is False and chk["conflicts"][0]["title"] == "既存"
    assert client.post("/api/v1/reservations", headers=H, json=payload).status_code == 409
    r = client.post("/api/v1/reservations", headers=H, json={**payload, "force": True})
    assert r.status_code == 201 and r.json()["reservation"]["repeat_label"] == "月−金"
    assert "<scheduledConditionID>w15</scheduledConditionID>" in fx.created[-1] and "desiredMatchingID" not in fx.created[-1]
    bad = client.post("/api/v1/reservations", headers=H, json={"broadcasting": "bs", "service_id": 101})
    assert bad.status_code == 422


def test_status_and_defaults(client):
    st = client.get("/api/v1/recorder", headers=H).json()
    assert st["model"] == "BDZ-TEST" and st["firmware"] == "35.003.1" and st["epg"]["td"]["channels"] == 2
    assert st["storage"] == {"destination": "HDD", "total_bytes": 4_294_967_296_000, "free_bytes": 8_556_380_160}
    d = client.get("/api/v1/defaults", headers=H).json()
    assert d["genres"]["3"] == "ドラマ"
    assert d["quality"] == "LSR" and d["repeats"]["title"] == "番組名"


def test_unconfigured_mode(tmp_path, monkeypatch):
    from bdzbridge.api import app as appmod
    from bdzbridge.recorder import discovery as disc

    async def _reachable(host, port, timeout=2.0):
        return True

    monkeypatch.setattr(appmod.wol, "port_open", _reachable)

    settings = Settings(recorder_host="", api_token=TOKEN, db_path=str(tmp_path / "u.sqlite3"), epg_refresh_on_start=False)
    store = Store(settings.db_path)
    bridge = Bridge(settings, None, store)
    app = create_app(settings, bridge)
    cand = disc.Candidate("192.0.2.10", 64220, "BDR - X", "BDZ-X", "BDZ-2021", "uuid:abc", True, "loc", "scan")

    async def fake_discover(self):
        return [cand]

    async def fake_set(self, host, persist=True):
        assert host == "192.0.2.10"
        self.recorder = FakeRecorder()
        await self.recorder.discover()
        if persist:
            store.set_meta("recorder_host", host)
            store.set_meta("recorder_udn", "uuid:abc")
        return self.recorder
    monkeypatch.setattr(Bridge, "discover", fake_discover)
    monkeypatch.setattr(Bridge, "set_recorder", fake_set)
    with TestClient(app) as c:
        st = c.get("/api/v1/recorder", headers=H).json()
        assert st["configured"] is False and st["host"] is None
        assert c.get("/api/v1/reservations", headers=H).status_code == 503
        assert c.get("/api/v1/channels", headers=H).status_code == 200  # cache still readable
        found = c.get("/api/v1/recorders/discover", headers=H).json()
        assert found[0]["host"] == "192.0.2.10" and found[0]["selected"] is False
        st = c.put("/api/v1/recorder", headers=H, json={"host": "192.0.2.10"}).json()
        assert st["configured"] is True and st["product"] == "BDZ-TEST"
        assert store.get_meta("recorder_udn") == "uuid:abc"
        assert c.get("/api/v1/reservations", headers=H).status_code == 200


def test_search_ignores_width_and_case(client):
    for term in ["sample", "ＳＡＭＰＬＥ", "Vivant"]:
        ps = client.get("/api/v1/programs", headers=H, params={"q": term}).json()
        assert [p["event_id"] for p in ps] == [14794], term


def test_reservation_update(client):
    r = client.post("/api/v1/reservations", headers=H, json={"broadcasting": "td", "service_id": 1024, "event_id": 14792}).json()["reservation"]
    u = client.patch(f"/api/v1/reservations/{r['id']}", headers=H, json={"quality": "LR", "repeat": "mon-fri"})
    assert u.status_code == 200, u.text
    body = u.json()
    assert body["id"] == r["id"] and body["quality"] == "LR" and body["repeat"] == "mon-fri" and body["event_id"] == 14792
    xml = client.bridge.recorder.xsrs.created[-1]
    assert f'<item id="{r["id"]}">' in xml and "<desiredQualityMode>250</desiredQualityMode>" in xml and ",,0x400,0x39c8" in xml
    assert client.patch("/api/v1/reservations/0xnope", headers=H, json={"quality": "LR"}).status_code == 404


def test_epg_refresh_skips_recorders_without_epg(client):
    from bdzbridge.recorder.client import RecorderInfo
    client.bridge.recorder.info = RecorderInfo("127.0.0.1", "BDR - OLD", "BDZ-OLD", "BDZ-OLD", False, "uuid:old")
    res = client.post("/api/v1/epg/refresh", headers=H).json()
    assert res["epg_capable"] is False
    st = client.get("/api/v1/recorder", headers=H).json()
    assert st["epg_capable"] is False


def test_titles_and_detail(client):
    ts = client.get("/api/v1/titles", headers=H).json()
    assert ts[0]["dlna_id"] == "V_216440" and ts[0]["is_new"]
    d = client.get("/api/v1/titles/0x0000010000034d78", headers=H).json()
    assert d["summary"] == "あらすじ" and d["details"] == ["番組内容 本文"] and d["id"] == "0x0000010000034d78"


def test_play_on_tv_and_stop(client):
    r = client.post("/api/v1/titles/0x0000010000034d78/play", headers=H)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["play"] == "Playing" and body["title_id"] == "0x0000010000034d78" and body["position_sec"] == 7 and body["chapter"] == 2
    assert client.bridge.recorder.xsrs.plays[-1] == ("0x0000010000034d78", "play", 0)
    st = client.get("/api/v1/recorder/playback", headers=H).json()
    assert st["play"] == "Playing"
    assert client.post("/api/v1/recorder/playback", headers=H, json={"operation": "resume"}).status_code == 409
    assert client.post("/api/v1/recorder/playback", headers=H, json={"operation": "pause"}).json()["play"] == "Paused"
    assert client.post("/api/v1/recorder/playback", headers=H, json={"operation": "resume"}).json()["play"] == "Playing"
    assert client.bridge.recorder.xsrs.plays[-1] == ("0x0000010000034d78", "pause", 0)
    r = client.post("/api/v1/recorder/playback", headers=H, json={"operation": "stop"})
    assert r.status_code == 200 and r.json()["play"] == "Stopped"
    assert client.post("/api/v1/recorder/playback", headers=H, json={"operation": "stop"}).status_code == 409


def test_channels_carry_logos(client):
    client.post("/api/v1/epg/refresh", headers=H)
    by_id = {c["service_id"]: c for c in client.get("/api/v1/channels?broadcasting=td", headers=H).json()}
    assert by_id[1024]["logo"].startswith("data:image/png;base64,")
    assert b"PLTE" in base64.b64decode(by_id[1024]["logo"].split(",", 1)[1])
    assert by_id[1025]["logo"] is None


def test_programs_compact_drops_text(client):
    client.post("/api/v1/epg/refresh", headers=H)
    full = client.get("/api/v1/programs?broadcasting=td&service_id=1024", headers=H).json()
    compact = client.get("/api/v1/programs?broadcasting=td&service_id=1024&compact=true", headers=H).json()
    assert [p["title"] for p in full] == [p["title"] for p in compact]
    assert any(p["description"] for p in full) and not any(p["description"] or p["extended"] for p in compact)


def test_reservations_carry_program_genres(client):
    client.post("/api/v1/epg/refresh", headers=H)
    r = client.post("/api/v1/reservations", headers=H,
                    json={"broadcasting": "td", "service_id": 1024, "event_id": 14792, "quality": "LSR", "repeat": "none"})
    assert r.status_code == 201, r.text
    res = [x for x in client.get("/api/v1/reservations", headers=H).json() if x["event_id"] == 14792]
    assert res and [g["label"] for g in res[0]["genres"]] == ["ニュース／報道", "ニュース／報道"]
    assert res[0]["genres"][1]["level2"] == 1


def test_titles_and_reservations_fall_back_to_genre_code(client):
    from bdzbridge.api.app import reservation_out
    from bdzbridge.recorder.xsrs import Reservation

    ts = client.get("/api/v1/titles", headers=H).json()
    assert [g["label"] for g in ts[0]["genres"]] == ["ドラマ"] and ts[0]["genres"][0]["level2"] == 0
    r = Reservation("0x1", "x", datetime(2026, 9, 14, 20, 0, tzinfo=JST), 1800, "1", 2, 1024, None, 230, False, False, "HDD", None, None,
                    genre_code=112)
    assert [g.label for g in reservation_out(r).genres] == ["アニメ／特撮"]


class FakeNotifier:
    configured = email_configured = True
    webhook_configured = False

    def __init__(self):
        self.sent = []
        self.s = type("S", (), {"notify_to": "me@example.com", "notify_free_gb": 50.0})()

    async def send(self, subject, body):
        self.sent.append((subject, body))
        return ["email"]


def _autorec_client(client):
    client.bridge.notifier = FakeNotifier()
    client.bridge.clock = lambda: datetime(2026, 9, 14, 4, 30, tzinfo=JST)
    return client


def test_rules_reserve_matching_programs_once(client):
    c = _autorec_client(client)
    r = c.post("/api/v1/rules", headers=H, json={"query": "sample"}, params={"run": "true"})
    assert r.status_code == 201 and r.json()["quality"] == "LSR" and r.json()["title_only"] is True
    rid = r.json()["id"]
    assert [m["event_id"] for m in c.get(f"/api/v1/rules/{rid}/matches", headers=H).json()] == [14794]
    res = [x for x in c.get("/api/v1/reservations", headers=H).json() if x["event_id"] == 14794]
    assert len(res) == 1 and res[0]["title"] == "日曜劇場「サンプルドラマ」" and res[0]["quality"] == "LSR"
    logs = c.get("/api/v1/rules/log", headers=H).json()
    assert [(x["status"], x["event_id"], x["rule_query"]) for x in logs] == [("reserved", 14794, "sample")]
    sent = c.bridge.notifier.sent
    assert len(sent) == 1 and sent[0][0] == "[bdzbridge] 自動予約 1 件" and "ＳＡＭＰＬＥ" in sent[0][1] and "「sample」" in sent[0][1]
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
    c = _autorec_client(client)
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
    c = _autorec_client(client)
    c.post("/api/v1/rules", headers=H, json={"query": "ニュース", "title_only": False})
    res = c.post("/api/v1/epg/refresh", headers=H).json()
    assert res["auto"]["reserved"] == 1 and c.bridge.last_autorec["reserved"] == 1
    assert c.get("/api/v1/notify", headers=H).json()["configured"] is True


def test_title_protect_flag(client):
    r = client.patch("/api/v1/titles/0x0000010000034d78", headers=H, json={"protected": True})
    assert r.status_code == 200 and r.json() == {"id": "0x0000010000034d78", "protected": True, "is_new": None, "title": None}
    assert client.bridge.recorder.xsrs.title_updates == [("0x0000010000034d78", {"titleProtectFlag": "1"})]
    client.patch("/api/v1/titles/0x0000010000034d78", headers=H, json={"protected": False, "is_new": False})
    assert client.bridge.recorder.xsrs.title_updates[-1][1] == {"titleProtectFlag": "0", "titleNewFlag": "0"}
    assert client.patch("/api/v1/titles/0x0000010000034d78", headers=H, json={}).status_code == 422


def test_title_delete(client):
    assert client.delete("/api/v1/titles/0x0000010000034d78", headers=H).status_code == 204
    assert client.bridge.recorder.xsrs.deleted == {"0x0000010000034d78"}
    assert client.delete("/api/v1/titles/0x0000010000034d78", headers=H).status_code == 404


def test_title_groups_and_bulk_delete(client):
    groups = client.get("/api/v1/titles/groups", headers=H).json()
    assert [(g["name"], g["count"], g["protected_count"], g["size_mb"]) for g in groups] == [("録画したドラマ", 3, 1, 12676), ("別の番組", 1, 0, 900)]
    key = groups[0]["key"]
    members = client.get("/api/v1/titles", headers=H, params={"series": key}).json()
    assert [m["id"] for m in members] == ["0x0000010000034d78", "0x0000010000034d79", "0x0000010000034d7b"] and members[0]["series"] == key
    assert [g["name"] for g in client.get("/api/v1/titles/groups", headers=H, params={"genre": 0}).json()] == ["別の番組"]
    job = client.post("/api/v1/titles/delete", headers=H, json={"ids": ["0x0000010000034d78", "0x0000010000034d79", "0x1"]})
    assert job.status_code == 202 and job.json()["total"] == 3
    for _ in range(100):
        r = client.get(f"/api/v1/titles/delete/{job.json()['id']}", headers=H).json()
        if r["finished"]:
            break
        time.sleep(0.02)
    assert r["finished"] and r["done"] == 3 and r["error"] is None
    assert r["deleted"] == ["0x0000010000034d78"]
    assert [(s["id"], s["reason"]) for s in r["skipped"]] == [("0x0000010000034d79", "protected"), ("0x1", "not found")]
    assert [g["count"] for g in client.get("/api/v1/titles/groups", headers=H).json()] == [2, 1]
    assert client.get("/api/v1/titles/delete/nope", headers=H).status_code == 404


def test_recorder_wake(client, monkeypatch):
    from bdzbridge.api import app as appmod

    calls = []
    monkeypatch.setattr(appmod.wol, "port_open", lambda host, port, timeout=2.0: _false())
    monkeypatch.setattr(appmod.wol, "wake", lambda host, mac, port=64220, wait=25.0: _true(calls, mac))
    assert client.post("/api/v1/recorder/wake", headers=H).status_code == 409  # MAC unknown
    client.bridge.store.set_meta("recorder_mac", "f8:4e:17:00:00:00")
    st = client.get("/api/v1/recorder", headers=H).json()
    assert st["reachable"] is False and st["mac"] == "f8:4e:17:00:00:00" and st["configured"] is True
    r = client.post("/api/v1/recorder/wake", headers=H).json()
    assert r == {"awake": True, "mac": "f8:4e:17:00:00:00"} and calls == ["f8:4e:17:00:00:00"]


async def _false():
    return False


async def _true(calls, mac):
    calls.append(mac)
    return True


def test_watch_state_and_monitor(client):
    ts = {t["id"]: t for t in client.get("/api/v1/titles", headers=H).json()}
    assert ts["0x0000010000034d78"]["watch_state"] == "unwatched"
    assert ts["0x0000010000034d79"]["watch_state"] == "partway" and ts["0x0000010000034d79"]["resume_sec"] == 754
    assert ts["0x0000010000034d7a"]["watch_state"] == "watched"
    c = _autorec_client(client)
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


def test_duplicate_scan_suggests_the_later_copy(client):
    job = client.post("/api/v1/titles/duplicates", headers=H)
    assert job.status_code == 202
    for _ in range(100):
        r = client.get(f"/api/v1/titles/duplicates/{job.json()['id']}", headers=H).json()
        if r["finished"]:
            break
        time.sleep(0.02)
    assert r["error"] is None and r["total"] == 2 and r["done"] == 2
    assert len(r["sets"]) == 1
    s = r["sets"][0]
    assert s["confidence"] == "high" and {i["id"] for i in s["items"]} == {"0x0000010000034d78", "0x0000010000034d7b"}
    assert s["keep"] == "0x0000010000034d7b" and s["suggest_delete"] == ["0x0000010000034d78"]  # the earlier broadcast stays
    assert s["reasons"]["0x0000010000034d7b"] == "先に放送" and s["reasons"]["0x0000010000034d78"] == "後の放送"
    assert client.bridge.store.title_summary("0x0000010000034d78") == "あらすじ"


def test_channel_prefs_hide_and_reorder(client):
    ids = lambda r: [c["service_id"] for c in r]
    assert ids(client.get("/api/v1/channels?broadcasting=td", headers=H).json()) == [1024, 1025]
    r = client.put("/api/v1/channels/td/prefs", headers=H, json={"order": [1025, 1024]}).json()
    assert ids(r) == [1025, 1024] and all(c["hidden"] is False for c in r)
    r = client.put("/api/v1/channels/td/prefs", headers=H, json={"hidden": [1024]}).json()
    assert [(c["service_id"], c["hidden"]) for c in r] == [(1025, False), (1024, True)]
    assert ids(client.get("/api/v1/channels?broadcasting=td", headers=H).json()) == [1025]
    assert ids(client.get("/api/v1/channels?broadcasting=td&include_hidden=true", headers=H).json()) == [1025, 1024]
    # hidden channels disappear from the guide and search unless asked for
    assert client.get("/api/v1/programs?broadcasting=td&q=ニュース", headers=H).json() == []
    assert len(client.get("/api/v1/programs?broadcasting=td&q=ニュース&include_hidden=true", headers=H).json()) == 1
    r = client.put("/api/v1/channels/td/prefs", headers=H, json={"order": [], "hidden": []}).json()
    assert ids(r) == [1024, 1025] and not any(c["hidden"] for c in r)


def test_bulk_protect_job(client):
    job = client.post("/api/v1/titles/protect", headers=H, json={"ids": ["0x0000010000034d78", "0x0000010000034d79", "0x1"], "protected": True})
    assert job.status_code == 202
    for _ in range(100):
        r = client.get(f"/api/v1/titles/protect/{job.json()['id']}", headers=H).json()
        if r["finished"]:
            break
        time.sleep(0.02)
    assert r["changed"] == ["0x0000010000034d78"] and r["done"] == 3 and r["error"] is None
    assert [(x["id"], x["reason"]) for x in r["skipped"]] == [("0x0000010000034d79", "unchanged"), ("0x1", "not found")]
    assert client.bridge.recorder.xsrs.title_updates[-1] == ("0x0000010000034d78", {"titleProtectFlag": "1"})


def _wait_job(client, kind, job_id):
    for _ in range(200):
        r = client.get(f"/api/v1/titles/{kind}/{job_id}", headers=H).json()
        if r["finished"]:
            return r
        time.sleep(0.02)
    raise AssertionError("job did not finish")


def _title(tid, title, start, duration=1800, **kw):
    from bdzbridge.recorder.xsrs import RecordedTitle

    args = {"id": tid, "title": title, "start": start, "duration_sec": duration, "broadcasting_type": 2, "service_id": 1024,
            "quality_code": 230, "protected": False, "is_new": True, "destination": "HDD", "size_mb": 1000, "genre_code": 48}
    args.update(kw)
    return RecordedTitle(**args)


def test_duplicates_keep_protected_partway_and_better_quality(client):
    x = client.bridge.recorder.xsrs
    t0 = datetime(2026, 9, 1, 21, 0, tzinfo=JST)
    x.extra_titles = [
        # same programme three times: the protected copy must be kept even though it aired last
        _title("0xa1", "ドラマＡ　第３話", t0), _title("0xa2", "ドラマＡ　第３話[再]", t0 + timedelta(days=3)),
        _title("0xa3", "ドラマＡ　第３話", t0 + timedelta(days=7), protected=True),
        # partly watched copy wins over the earlier untouched one
        _title("0xb1", "ドラマＢ　第１話", t0), _title("0xb2", "ドラマＢ　第１話", t0 + timedelta(days=1), is_new=False, resume_sec=600),
        # same start, different quality: DR is kept, LSR suggested
        _title("0xc1", "ドラマＣ", t0, quality_code=240, size_mb=500), _title("0xc2", "ドラマＣ", t0, quality_code=100, size_mb=5000),
        # same title but a daily show whose descriptions differ: not duplicates
        _title("0xd1", "朝の番組", t0), _title("0xd2", "朝の番組", t0 + timedelta(days=1)),
        # same title, clearly different length: not duplicates
        _title("0xe1", "スペシャル", t0, duration=3600), _title("0xe2", "スペシャル", t0 + timedelta(days=1), duration=7200),
    ]
    x.summaries = {"0xd1": "月曜のあらすじ", "0xd2": "火曜のあらすじ", "0xc1": "", "0xc2": ""}
    job = client.post("/api/v1/titles/duplicates", headers=H).json()
    r = _wait_job(client, "duplicates", job["id"])
    sets = {s["title"][:4]: s for s in r["sets"]}
    assert set(sets) == {"ドラマＡ", "ドラマＢ", "ドラマＣ", "録画した"}
    a = sets["ドラマＡ"]
    assert a["keep"] == "0xa3" and a["reasons"]["0xa3"] == "保護中" and sorted(a["suggest_delete"]) == ["0xa1", "0xa2"]
    b = sets["ドラマＢ"]
    assert b["keep"] == "0xb2" and b["reasons"]["0xb2"] == "視聴途中" and b["suggest_delete"] == ["0xb1"]
    c = sets["ドラマＣ"]
    assert c["keep"] == "0xc2" and c["reasons"]["0xc2"] == "高画質" and c["reasons"]["0xc1"] == "低画質" and c["confidence"] == "low"
    from bdzbridge.recorder.xsrs import RecordedTitle  # noqa: F401


def test_bulk_unprotect_job(client):
    job = client.post("/api/v1/titles/protect", headers=H, json={"ids": ["0x0000010000034d79", "0x0000010000034d78"], "protected": False}).json()
    r = _wait_job(client, "protect", job["id"])
    assert r["changed"] == ["0x0000010000034d79"] and [x["reason"] for x in r["skipped"]] == ["unchanged"]
    assert client.bridge.recorder.xsrs.title_updates[-1] == ("0x0000010000034d79", {"titleProtectFlag": "0"})


def test_monitor_warns_again_only_after_space_recovers(client):
    c = _autorec_client(client)
    x = c.bridge.recorder.xsrs
    assert c.post("/api/v1/monitor/run", headers=H).json()["low_space"] is True
    x.record_destination_info = lambda destination="HDD": _free(55e9)  # above 50 but below the 60 GB re-arm line
    assert c.post("/api/v1/monitor/run", headers=H).json()["low_space"] is False
    x.record_destination_info = lambda destination="HDD": _free(200e9)
    assert c.post("/api/v1/monitor/run", headers=H).json()["low_space"] is False  # recovered: warning re-armed
    x.record_destination_info = lambda destination="HDD": _free(10e9)
    assert c.post("/api/v1/monitor/run", headers=H).json()["low_space"] is True
    assert len(c.bridge.notifier.sent) == 2


async def _free(free_bytes):
    return {"total_bytes": 4_000_000_000_000, "free_bytes": int(free_bytes)}


def test_monitor_free_space_check_can_be_disabled(tmp_path, monkeypatch):
    from bdzbridge.api import app as appmod

    async def _reachable(host, port, timeout=2.0):
        return True

    monkeypatch.setattr(appmod.wol, "port_open", _reachable)
    settings = Settings(recorder_host="127.0.0.1", api_token=TOKEN, db_path=str(tmp_path / "m.sqlite3"), epg_refresh_on_start=False,
                        notify_free_gb=0)
    store = Store(settings.db_path)
    bridge = Bridge(settings, FakeRecorder(), store)
    bridge.notifier = FakeNotifier()
    with TestClient(create_app(settings, bridge)) as c:
        r = c.post("/api/v1/monitor/run", headers=H).json()
    assert r["free_gb"] is None and r["low_space"] is False and bridge.notifier.sent == []


def test_hidden_channels_are_skipped_by_rules(client):
    c = _autorec_client(client)
    c.put("/api/v1/channels/td/prefs", headers=H, json={"hidden": [1024]})
    rid = c.post("/api/v1/rules", headers=H, json={"query": "sample"}).json()["id"]
    assert c.get(f"/api/v1/rules/{rid}/matches", headers=H).json() == []
    assert c.post("/api/v1/rules/run", headers=H).json()["reserved"] == 0
    c.put("/api/v1/channels/td/prefs", headers=H, json={"hidden": []})
    assert [m["event_id"] for m in c.get(f"/api/v1/rules/{rid}/matches", headers=H).json()] == [14794]


def test_rules_match_description_when_not_title_only(client):
    c = _autorec_client(client)
    only = c.post("/api/v1/rules", headers=H, json={"query": "朝のニュース", "title_only": True}).json()
    wide = c.post("/api/v1/rules", headers=H, json={"query": "朝のニュース", "title_only": False}).json()
    assert c.get(f"/api/v1/rules/{only['id']}/matches", headers=H).json() == []
    assert [m["event_id"] for m in c.get(f"/api/v1/rules/{wide['id']}/matches", headers=H).json()] == [14792]


def test_power_on_wakes_an_unreachable_recorder(client, monkeypatch):
    from bdzbridge.api import app as appmod

    async def _down(host, port, timeout=2.0):
        return False

    woke = []

    async def _wake(host, mac, port=64220, wait=25.0):
        woke.append(mac)
        return True

    monkeypatch.setattr(appmod.wol, "port_open", _down)
    monkeypatch.setattr(appmod.wol, "wake", _wake)
    client.bridge.store.set_meta("recorder_mac", "f8:4e:17:00:00:00")
    assert client.post("/api/v1/recorder/power", headers=H).json() == {"power": "PowerOn"}
    assert woke == ["f8:4e:17:00:00:00"] and client.bridge.recorder.xsrs.powered == 1


def test_channel_prefs_partial_order_keeps_the_rest_behind(client):
    r = client.put("/api/v1/channels/td/prefs", headers=H, json={"order": [1025]}).json()
    assert [c["service_id"] for c in r] == [1025, 1024]
    # a broadcasting type without channels accepts preferences without complaint
    assert client.put("/api/v1/channels/cs/prefs", headers=H, json={"hidden": [1]}).json() == []
