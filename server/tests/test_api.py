from __future__ import annotations

import asyncio
import base64
import time
import xml.etree.ElementTree as ET
from datetime import datetime

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
        all_ = [RecordedTitle("0x0000010000034d78", "録画したドラマ", datetime(2026, 9, 13, 21, 0, tzinfo=JST), 4148, 2, 1048, 230,
                              False, True, "HDD", 4376, genre_code=48),
                RecordedTitle("0x0000010000034d79", "録画したドラマ　第２話[字]", datetime(2026, 9, 12, 21, 0, tzinfo=JST), 3600, 2, 1048, 230,
                              True, False, "HDD", 4000, genre_code=48),
                RecordedTitle("0x0000010000034d7a", "別の番組[字]", datetime(2026, 9, 11, 21, 0, tzinfo=JST), 1800, 2, 1024, 240,
                              False, False, "HDD", 900, genre_code=0)]
        return [t for t in all_ if t.id not in deleted]

    async def list_titles(self, count=100, start=0):
        return self._titles()[start:start + count]

    async def list_titles_all(self, page=200):
        return self._titles()

    async def title_detail(self, title_id):
        return {"summary": "あらすじ", "details": ["番組内容 本文"]}

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
def client(tmp_path):
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
    from bdzbridge.recorder import discovery as disc

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
        self.s = type("S", (), {"notify_to": "me@example.com"})()

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
    assert [(g["name"], g["count"], g["protected_count"], g["size_mb"]) for g in groups] == [("録画したドラマ", 2, 1, 8376), ("別の番組", 1, 0, 900)]
    key = groups[0]["key"]
    members = client.get("/api/v1/titles", headers=H, params={"series": key}).json()
    assert [m["id"] for m in members] == ["0x0000010000034d78", "0x0000010000034d79"] and members[0]["series"] == key
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
    assert [g["count"] for g in client.get("/api/v1/titles/groups", headers=H).json()] == [1, 1]
    assert client.get("/api/v1/titles/delete/nope", headers=H).status_code == 404
