from __future__ import annotations

from fastapi.testclient import TestClient

from bdzbridge.api.app import create_app
from bdzbridge.config import Settings
from bdzbridge.recorder import wol
from bdzbridge.state import Bridge
from bdzbridge.store import Store
from tests.conftest import (
    TOKEN,
    FakeRecorder,
    H,
)


def test_auth_required(client):
    assert client.get("/api/v1/channels").status_code == 401
    assert client.get("/api/v1/channels", headers={"Authorization": "Bearer wrong"}).status_code == 401

def test_status_and_defaults(client):
    st = client.get("/api/v1/recorder", headers=H).json()
    assert st["model"] == "BDZ-TEST" and st["firmware"] == "35.003.1" and st["epg"]["td"]["channels"] == 2
    assert st["storage"] == {"destination": "HDD", "total_bytes": 4_294_967_296_000, "free_bytes": 8_556_380_160}
    d = client.get("/api/v1/defaults", headers=H).json()
    assert d["genres"]["3"] == "ドラマ"
    assert d["quality"] == "LSR" and d["repeats"]["title"] == "番組名"

def test_unconfigured_mode(tmp_path, monkeypatch):
    from bdzbridge.recorder import discovery as disc

    async def _reachable(host, port, timeout=2.0):
        return True

    monkeypatch.setattr(wol, "port_open", _reachable)

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

def test_epg_refresh_skips_recorders_without_epg(client):
    from bdzbridge.recorder.client import RecorderInfo
    client.bridge.recorder.info = RecorderInfo("127.0.0.1", "BDR - OLD", "BDZ-OLD", "BDZ-OLD", False, "uuid:old")
    res = client.post("/api/v1/epg/refresh", headers=H).json()
    assert res["epg_capable"] is False
    st = client.get("/api/v1/recorder", headers=H).json()
    assert st["epg_capable"] is False

def test_recorder_wake(client, monkeypatch):

    calls = []
    monkeypatch.setattr(wol, "port_open", lambda host, port, timeout=2.0: _false())
    monkeypatch.setattr(wol, "wake", lambda host, mac, port=64220, wait=25.0: _true(calls, mac))
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

def test_power_on_wakes_an_unreachable_recorder(client, monkeypatch):

    async def _down(host, port, timeout=2.0):
        return False

    woke = []

    async def _wake(host, mac, port=64220, wait=25.0):
        woke.append(mac)
        return True

    monkeypatch.setattr(wol, "port_open", _down)
    monkeypatch.setattr(wol, "wake", _wake)
    client.bridge.store.set_meta("recorder_mac", "f8:4e:17:00:00:00")
    assert client.post("/api/v1/recorder/power", headers=H).json() == {"power": "PowerOn"}
    assert woke == ["f8:4e:17:00:00:00"] and client.bridge.recorder.xsrs.powered == 1
