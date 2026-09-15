from __future__ import annotations

import base64

from tests.conftest import (
    H,
)


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

def test_search_ignores_width_and_case(client):
    for term in ["sample", "SAMPLE", "ＳＡＭＰＬＥ"]:
        ps = client.get("/api/v1/programs", headers=H, params={"q": term}).json()
        assert [p["event_id"] for p in ps] == [14794], term

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

def test_channel_prefs_partial_order_keeps_the_rest_behind(client):
    r = client.put("/api/v1/channels/td/prefs", headers=H, json={"order": [1025]}).json()
    assert [c["service_id"] for c in r] == [1025, 1024]
    # a broadcasting type without channels accepts preferences without complaint
    assert client.put("/api/v1/channels/cs/prefs", headers=H, json={"hidden": [1]}).json() == []
