from __future__ import annotations

import asyncio
import xml.etree.ElementTree as ET
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from recbridge.api.app import Bridge, create_app
from recbridge.config import Settings
from recbridge.recorder.epg import JST
from recbridge.recorder.xsrs import Reservation, parse_reservation
from recbridge.store import Store
from tests.conftest import make_services

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

    async def list_titles(self, count=100, start=0):
        return []

    async def play_status(self):
        return {"powerstatus": "PowerOn", "playstatus": "Stopped"}

    async def firmware_version(self):
        return "35.003.1"


class FakeRecorder:
    def __init__(self):
        self.xsrs = FakeXsrs()
        self.lock = asyncio.Lock()
        self.info = None

    async def discover(self):
        from recbridge.recorder.client import RecorderInfo
        self.info = RecorderInfo("127.0.0.1", "BDR - TEST", "BDZ-TEST", "BDZ-TEST", True, "uuid:x")
        return self.info

    async def fetch_epg(self, bt):
        return make_services() if bt == "td" else None

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
    d = client.get("/api/v1/defaults", headers=H).json()
    assert d["quality"] == "LSR" and d["repeats"]["title"] == "番組名"


def test_unconfigured_mode(tmp_path, monkeypatch):
    from recbridge.recorder import discovery as disc

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
    from recbridge.recorder.client import RecorderInfo
    client.bridge.recorder.info = RecorderInfo("127.0.0.1", "BDR - OLD", "BDZ-OLD", "BDZ-OLD", False, "uuid:old")
    res = client.post("/api/v1/epg/refresh", headers=H).json()
    assert res["epg_capable"] is False
    st = client.get("/api/v1/recorder", headers=H).json()
    assert st["epg_capable"] is False
