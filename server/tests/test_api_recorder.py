from __future__ import annotations

from fastapi.testclient import TestClient

from bdzbridge.api.app import create_app
from bdzbridge.config import PLACEHOLDER_TOKEN, Settings
from bdzbridge.recorder import discovery, wol
from bdzbridge.services import session
from bdzbridge.state import Bridge
from bdzbridge.store import Store
from tests.conftest import (
    TOKEN,
    FakeRecorder,
    H,
    autorec_client,
)


def test_auth_required(client):
    assert client.get("/api/v1/channels").status_code == 401
    assert client.get("/api/v1/channels", headers={"Authorization": "Bearer wrong"}).status_code == 401

def test_the_examples_placeholder_token_is_refused(tmp_path):
    settings = Settings(recorder_host="", api_token=PLACEHOLDER_TOKEN, db_path=str(tmp_path / "p.sqlite3"),
                        epg_refresh_on_start=False)
    with TestClient(create_app(settings, Bridge(settings, None, Store(settings.db_path)))) as c:
        assert c.get("/api/v1/channels", headers={"Authorization": f"Bearer {PLACEHOLDER_TOKEN}"}).status_code == 401
        assert c.get("/api/v1/channels", headers={"Authorization": f"Bearer {settings.api_token}"}).status_code == 200
    assert len(settings.api_token) >= 24

async def test_a_saved_recorder_that_moved_is_found_again_by_udn(tmp_path, monkeypatch):
    settings = Settings(recorder_host="", api_token=TOKEN, db_path=str(tmp_path / "m.sqlite3"), epg_refresh_on_start=False)
    store = Store(settings.db_path)
    store.set_meta("recorder_host", "192.0.2.10")
    store.set_meta("recorder_udn", "uuid:abc")
    bridge = Bridge(settings, None, store)

    async def silent(host, http, port=64220, via="manual"):
        return None

    async def found(http, networks=""):
        return [discovery.Candidate("192.0.2.30", 64220, "BDR - Y", "BDZ-Y", "BDZ-2021", "uuid:other", True, "loc", "scan"),
                discovery.Candidate("192.0.2.20", 64220, "BDR - X", "BDZ-X", "BDZ-2021", "uuid:abc", True, "loc", "scan")]
    picked = []

    async def pick(b, host, persist=True):
        picked.append((host, persist))
        b.recorder = FakeRecorder()
        return b.recorder
    monkeypatch.setattr(discovery, "probe", silent)
    monkeypatch.setattr(discovery, "discover", found)
    monkeypatch.setattr(session, "set_recorder", pick)
    await session.resolve_recorder(bridge)
    assert picked == [("192.0.2.20", True)]  # and saved, so that the next start goes straight there
    await bridge.close()

def test_the_server_starts_unconfigured_when_no_recorder_can_be_selected(tmp_path, monkeypatch):
    async def broken(bridge):
        raise RuntimeError("the network is not up yet")
    monkeypatch.setattr(session, "resolve_recorder", broken)
    settings = Settings(recorder_host="", api_token=TOKEN, db_path=str(tmp_path / "s.sqlite3"), epg_refresh_on_start=False)
    with TestClient(create_app(settings)) as c:
        st = c.get("/api/v1/recorder", headers=H).json()
        assert st["configured"] is False
        assert c.get("/api/v1/channels", headers=H).status_code == 200

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
    monkeypatch.setattr(session, "discover", fake_discover)
    monkeypatch.setattr(session, "set_recorder", fake_set)
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

def test_a_type_that_failed_stays_in_the_status_until_a_refresh_has_none(client):
    client = autorec_client(client)  # a refresh ends with the monitor, which must not notify anybody for real
    rec = client.bridge.recorder
    fetch = rec.fetch_epg

    async def bs_fails(bt):
        if bt == "bs":
            raise OSError("connection reset")
        return await fetch(bt)
    rec.fetch_epg = bs_fails
    res = client.post("/api/v1/epg/refresh", headers=H).json()
    assert res["bs"] == {"error": "connection reset"} and res["td"]["programs"] > 0
    assert client.get("/api/v1/recorder", headers=H).json()["epg"]["last_error"] == "bs: connection reset"
    rec.fetch_epg = fetch
    client.post("/api/v1/epg/refresh", headers=H)
    assert client.get("/api/v1/recorder", headers=H).json()["epg"]["last_error"] is None

def test_a_refresh_wakes_a_recorder_that_has_left_the_network(client, monkeypatch):
    client = autorec_client(client)
    woke = []

    async def _down(host, port, timeout=2.0):
        return False

    async def _wake(host, mac, port=64220, wait=25.0):
        woke.append(mac)
        return len(woke) == 1  # the first one wakes it, the second finds nothing
    monkeypatch.setattr(wol, "port_open", _down)
    monkeypatch.setattr(wol, "wake", _wake)
    client.bridge.settings.recorder_mac = ""
    client.bridge.store.set_meta("recorder_mac", "f8:4e:17:00:00:00")
    assert client.post("/api/v1/epg/refresh", headers=H).json()["td"]["programs"] > 0
    assert woke == ["f8:4e:17:00:00:00"]
    r = client.post("/api/v1/epg/refresh", headers=H)
    assert r.status_code == 503 and len(woke) == 2
    assert "Wake-on-LAN" in client.get("/api/v1/recorder", headers=H).json()["epg"]["last_error"]

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
