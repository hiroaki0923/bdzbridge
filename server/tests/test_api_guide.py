from __future__ import annotations

import base64

import httpx

from bdzbridge.recorder import codes
from bdzbridge.recorder.client import RecorderClient
from bdzbridge.services import epg
from tests.conftest import (
    H,
    autorec_client,
    make_services,
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


def test_a_guide_file_not_made_yet_is_said_once(client):
    asked = []

    async def not_made(bt):
        asked.append(bt)
        request = httpx.Request("GET", "http://192.0.2.10/EPG.dat")
        raise httpx.HTTPStatusError("500", request=request, response=httpx.Response(500, request=request))
    client.bridge.recorder.fetch_epg = not_made
    client.post("/api/v1/epg/refresh", headers=H)
    assert len(asked) == len(codes.EPG_FILES)
    assert client.bridge.last_error == epg.FILE_NOT_MADE


def refused(bt):
    request = httpx.Request("GET", f"http://192.0.2.10//{codes.EPG_FILES[bt]}")
    return httpx.HTTPStatusError("500", request=request, response=httpx.Response(500, request=request))


def answering(rec, *types):
    """The recorder gives a guide for `types` and refuses every other file, as a recorder without a tuner does."""
    async def fetch_epg(bt):
        if bt not in types:
            raise refused(bt)
        return make_services()
    rec.fetch_epg = fetch_epg


def test_a_type_never_read_is_no_failure_while_the_others_are_read(client):
    client = autorec_client(client)
    answering(client.bridge.recorder, "td", "bs", "cs")
    res = client.post("/api/v1/epg/refresh", headers=H).json()
    assert res["bs4k"] == res["cs4k"] == epg.NO_CHANNELS
    assert res["td"]["programs"] > 0
    assert client.bridge.last_error is None


def test_a_type_read_before_is_said_when_its_file_goes_missing(client):
    client = autorec_client(client)
    rec = client.bridge.recorder
    answering(rec, "td", "bs", "cs", "bs4k")
    client.post("/api/v1/epg/refresh", headers=H)
    assert client.bridge.last_error is None
    answering(rec, "td", "bs", "cs")
    res = client.post("/api/v1/epg/refresh", headers=H).json()
    assert res["bs4k"] == {"error": epg.FILE_NOT_MADE}
    assert res["cs4k"] == epg.NO_CHANNELS  # never read, as before
    assert client.bridge.last_error == epg.FILE_NOT_MADE


def test_a_type_appears_once_it_is_read(client):
    client = autorec_client(client)
    rec = client.bridge.recorder
    answering(rec, "td")
    client.post("/api/v1/epg/refresh", headers=H)
    assert client.get("/api/v1/recorder", headers=H).json()["epg"]["bs4k"]["channels"] == 0
    answering(rec, "td", "bs4k")
    client.post("/api/v1/epg/refresh", headers=H)
    assert client.get("/api/v1/recorder", headers=H).json()["epg"]["bs4k"]["channels"] > 0


def test_a_failure_that_is_no_refusal_is_said_though_the_type_was_never_read(client):
    client = autorec_client(client)
    rec = client.bridge.recorder

    async def garbled(bt):
        if bt == "bs4k":
            raise ValueError("not a guide file")
        return make_services() if bt == "td" else None
    rec.fetch_epg = garbled
    res = client.post("/api/v1/epg/refresh", headers=H).json()
    assert res["bs4k"] == {"error": "not a guide file"}
    assert client.bridge.last_error == "bs4k: not a guide file"


async def test_a_file_the_recorder_does_not_know_is_no_guide():
    recorder = RecorderClient("192.0.2.10")
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda request: httpx.Response(404))) as http:
        recorder.http = http
        assert await recorder.fetch_epg("bs4k") is None


def test_a_recorder_gone_partway_ends_the_refresh(client):
    asked = []

    async def gone(bt):
        asked.append(bt)
        raise httpx.ConnectTimeout("no answer")
    client.bridge.recorder.fetch_epg = gone
    client.post("/api/v1/epg/refresh", headers=H)
    assert len(asked) == 1
