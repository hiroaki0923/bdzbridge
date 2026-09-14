from __future__ import annotations

import asyncio
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from bdzbridge.api.app import create_app
from bdzbridge.config import Settings
from bdzbridge.recorder import wol
from bdzbridge.recorder.epg import JST, Program, Service
from bdzbridge.recorder.logo import Logo, with_palette
from bdzbridge.recorder.xsrs import RecordedTitle, Reservation, XsrsError, parse_reservation
from bdzbridge.state import Bridge
from bdzbridge.store import Store
from tests.test_logo import make_png

TOKEN = "t"
H = {"Authorization": f"Bearer {TOKEN}"}


def make_services() -> list[Service]:
    day = datetime(2026, 9, 14, 5, 0, tzinfo=JST)
    nhk = Service(1024, "ＮＨＫ総合１・東京", [
        Program(1024, 14792, day, day + timedelta(hours=1), "サンプルニュース　あさの放送", "朝のニュース", "詳細テキスト",
                genres=[(0, 0), (0, 1)], copy_control=2, parental_rating=0),
        Program(1024, 14793, day + timedelta(hours=1), day + timedelta(hours=1, minutes=15), "あさのサンプル", "生活情報", "",
                genres=[(2, 4)]),
        Program(1024, 14800, day + timedelta(days=1, hours=15), day + timedelta(days=1, hours=16), "翌日の番組", "", "x"),
        Program(1024, 14794, day + timedelta(hours=16), day + timedelta(hours=17), "日曜劇場「サンプルドラマ」", "", ""),
    ])
    sub = Service(1025, "ＮＨＫ総合２・東京", [
        Program(1025, 14792, day, day + timedelta(hours=1), ref_service_id=1024, ref_event_id=14792),
    ])
    return [nhk, sub]


@pytest.fixture
def services():
    return make_services()


# --- a recorder that answers like a BDZ but lives in memory, and the API client around it ---

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

    async def _reachable(host, port, timeout=2.0):  # nothing listens on 64220 in tests: pretend the recorder answers
        return True

    monkeypatch.setattr(wol, "port_open", _reachable)
    settings = Settings(recorder_host="127.0.0.1", api_token=TOKEN, db_path=str(tmp_path / "t.sqlite3"),
                       epg_refresh_on_start=False)
    store = Store(settings.db_path)
    store.replace_services("td", make_services())
    bridge = Bridge(settings, FakeRecorder(), store)
    app = create_app(settings, bridge)
    with TestClient(app) as c:
        c.bridge = bridge
        yield c


class FakeNotifier:
    configured = email_configured = True
    webhook_configured = False

    def __init__(self):
        self.sent = []
        self.s = type("S", (), {"notify_to": "me@example.com", "notify_free_gb": 50.0})()

    async def send(self, subject, body):
        self.sent.append((subject, body))
        return ["email"]


def autorec_client(client):
    client.bridge.notifier = FakeNotifier()
    client.bridge.clock = lambda: datetime(2026, 9, 14, 4, 30, tzinfo=JST)
    return client


def wait_job(client, kind, job_id):
    for _ in range(200):
        r = client.get(f"/api/v1/titles/{kind}/{job_id}", headers=H).json()
        if r["finished"]:
            return r
        time.sleep(0.02)
    raise AssertionError("job did not finish")


def make_title(tid, title, start, duration=1800, **kw):

    args = {"id": tid, "title": title, "start": start, "duration_sec": duration, "broadcasting_type": 2, "service_id": 1024,
            "quality_code": 230, "protected": False, "is_new": True, "destination": "HDD", "size_mb": 1000, "genre_code": 48}
    args.update(kw)
    return RecordedTitle(**args)


async def free_space(free_bytes):
    return {"total_bytes": 4_000_000_000_000, "free_bytes": int(free_bytes)}
