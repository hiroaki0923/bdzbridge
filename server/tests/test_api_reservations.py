from __future__ import annotations

from datetime import datetime

from bdzbridge.recorder.epg import JST
from bdzbridge.recorder.xsrs import Reservation
from tests.conftest import (
    H,
)


def test_reservation_from_event_id(client):
    r = client.post("/api/v1/reservations", headers=H, json={"broadcasting": "td", "service_id": 1024, "event_id": 14792})
    assert r.status_code == 201, r.text
    body = r.json()["reservation"]
    assert body["title"] == "ＮＨＫニュース　おはよう日本" and body["duration_sec"] == 3600 and body["tracks_program"]
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

def test_reservation_update(client):
    r = client.post("/api/v1/reservations", headers=H, json={"broadcasting": "td", "service_id": 1024, "event_id": 14792}).json()["reservation"]
    u = client.patch(f"/api/v1/reservations/{r['id']}", headers=H, json={"quality": "LR", "repeat": "mon-fri"})
    assert u.status_code == 200, u.text
    body = u.json()
    assert body["id"] == r["id"] and body["quality"] == "LR" and body["repeat"] == "mon-fri" and body["event_id"] == 14792
    xml = client.bridge.recorder.xsrs.created[-1]
    assert f'<item id="{r["id"]}">' in xml and "<desiredQualityMode>250</desiredQualityMode>" in xml and ",,0x400,0x39c8" in xml
    assert client.patch("/api/v1/reservations/0xnope", headers=H, json={"quality": "LR"}).status_code == 404

def test_reservations_carry_program_genres(client):
    client.post("/api/v1/epg/refresh", headers=H)
    r = client.post("/api/v1/reservations", headers=H,
                    json={"broadcasting": "td", "service_id": 1024, "event_id": 14792, "quality": "LSR", "repeat": "none"})
    assert r.status_code == 201, r.text
    res = [x for x in client.get("/api/v1/reservations", headers=H).json() if x["event_id"] == 14792]
    assert res and [g["label"] for g in res[0]["genres"]] == ["ニュース／報道", "ニュース／報道"]
    assert res[0]["genres"][1]["level2"] == 1

def test_titles_and_reservations_fall_back_to_genre_code(client):
    from bdzbridge.api.serializers import reservation_out
    from bdzbridge.recorder.xsrs import Reservation

    ts = client.get("/api/v1/titles", headers=H).json()
    assert [g["label"] for g in ts[0]["genres"]] == ["ドラマ"] and ts[0]["genres"][0]["level2"] == 0
    r = Reservation("0x1", "x", datetime(2026, 9, 14, 20, 0, tzinfo=JST), 1800, "1", 2, 1024, None, 230, False, False, "HDD", None, None,
                    genre_code=112)
    assert [g.label for g in reservation_out(r).genres] == ["アニメ／特撮"]


def test_weekly_repeat_must_match_the_programmes_weekday(client):
    # the fixture programme airs on Monday 2026-09-14
    r = client.post("/api/v1/reservations", headers=H, json={"broadcasting": "td", "service_id": 1024, "event_id": 14792, "repeat": "tue"})
    assert r.status_code == 422 and "weekday" in r.json()["detail"]
    r = client.post("/api/v1/reservations", headers=H, json={"broadcasting": "td", "service_id": 1024, "event_id": 14792, "repeat": "mon"})
    assert r.status_code == 201 and r.json()["reservation"]["repeat"] == "mon"
    rid = r.json()["reservation"]["id"]
    assert client.patch(f"/api/v1/reservations/{rid}", headers=H, json={"repeat": "sun"}).status_code == 422
    assert client.patch(f"/api/v1/reservations/{rid}", headers=H, json={"repeat": "daily"}).status_code == 200
