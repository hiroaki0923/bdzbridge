from __future__ import annotations

import time
from datetime import datetime, timedelta

import httpx

from bdzbridge.recorder.client import RecorderClient
from bdzbridge.recorder.epg import JST
from tests.conftest import (
    H,
    make_title,
    wait_job,
)


def test_titles_and_detail(client):
    ts = client.get("/api/v1/titles", headers=H).json()
    assert ts[0]["dlna_id"] == "V_216440" and ts[0]["is_new"]
    d = client.get("/api/v1/titles/0x0000010000034d78", headers=H).json()
    assert d["summary"] == "あらすじ" and d["details"] == ["番組内容 本文"] and d["id"] == "0x0000010000034d78"

def test_dlna_id_names_the_disk_the_title_lives_on():
    assert RecorderClient.cds_id("0x0000010000034d78") == "V_216440"
    assert RecorderClient.cds_id("0x0000010000034d78", "USBHDD") == "USBV_216440"


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
    r = wait_job(client, job.json()["id"])
    assert r["kind"] == "delete" and r["done"] == 3 and r["error"] is None and r["cancelled"] is False
    assert r["result"]["deleted"] == ["0x0000010000034d78"]
    assert [(s["id"], s["reason"]) for s in r["result"]["skipped"]] == [("0x0000010000034d79", "protected"), ("0x1", "not found")]
    assert [g["count"] for g in client.get("/api/v1/titles/groups", headers=H).json()] == [2, 1]
    assert client.get("/api/v1/jobs/nope", headers=H).status_code == 404

def test_duplicate_scan_suggests_the_later_copy(client):
    job = client.post("/api/v1/titles/duplicates", headers=H)
    assert job.status_code == 202
    r = wait_job(client, job.json()["id"])
    assert r["error"] is None and r["total"] == 2 and r["done"] == 2
    assert len(r["result"]["sets"]) == 1
    s = r["result"]["sets"][0]
    assert s["confidence"] == "high" and [i["id"] for i in s["items"]] == ["0x0000010000034d7b", "0x0000010000034d78"]  # broadcast order
    assert s["keep"] == "0x0000010000034d7b" and s["suggest_delete"] == ["0x0000010000034d78"]  # the earlier broadcast stays
    assert s["reasons"]["0x0000010000034d7b"] == "先に放送" and s["reasons"]["0x0000010000034d78"] == "後の放送"
    assert client.bridge.store.title_summary("0x0000010000034d78") == "あらすじ"

def test_bulk_protect_job(client):
    job = client.post("/api/v1/titles/protect", headers=H, json={"ids": ["0x0000010000034d78", "0x0000010000034d79", "0x1"], "protected": True})
    assert job.status_code == 202
    r = wait_job(client, job.json()["id"])
    assert r["result"]["changed"] == ["0x0000010000034d78"] and r["done"] == 3 and r["error"] is None
    assert [(x["id"], x["reason"]) for x in r["result"]["skipped"]] == [("0x0000010000034d79", "unchanged"), ("0x1", "not found")]
    assert client.bridge.recorder.xsrs.title_updates[-1] == ("0x0000010000034d78", {"titleProtectFlag": "1"})

def test_duplicates_keep_protected_partway_and_better_quality(client):
    x = client.bridge.recorder.xsrs
    t0 = datetime(2026, 9, 1, 21, 0, tzinfo=JST)
    x.extra_titles = [
        # same programme three times: the protected copy must be kept even though it aired last
        make_title("0xa1", "ドラマＡ　第３話", t0), make_title("0xa2", "ドラマＡ　第３話[再]", t0 + timedelta(days=3)),
        make_title("0xa3", "ドラマＡ　第３話", t0 + timedelta(days=7), protected=True),
        # partly watched copy wins over the earlier untouched one
        make_title("0xb1", "ドラマＢ　第１話", t0), make_title("0xb2", "ドラマＢ　第１話", t0 + timedelta(days=1), is_new=False, resume_sec=600),
        # same start, different quality: DR is kept, LSR suggested
        make_title("0xc1", "ドラマＣ", t0, quality_code=240, size_mb=500), make_title("0xc2", "ドラマＣ", t0, quality_code=100, size_mb=5000),
        # same title but a daily show whose descriptions differ: not duplicates
        make_title("0xd1", "朝の番組", t0), make_title("0xd2", "朝の番組", t0 + timedelta(days=1)),
        # same title, clearly different length: not duplicates
        make_title("0xe1", "スペシャル", t0, duration=3600), make_title("0xe2", "スペシャル", t0 + timedelta(days=1), duration=7200),
    ]
    x.summaries = {"0xd1": "月曜のあらすじ", "0xd2": "火曜のあらすじ", "0xc1": "", "0xc2": ""}
    job = client.post("/api/v1/titles/duplicates", headers=H).json()
    r = wait_job(client, job["id"])
    sets = {s["title"][:4]: s for s in r["result"]["sets"]}
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
    r = wait_job(client, job["id"])
    assert r["result"]["changed"] == ["0x0000010000034d79"] and [x["reason"] for x in r["result"]["skipped"]] == ["unchanged"]
    assert client.bridge.recorder.xsrs.title_updates[-1] == ("0x0000010000034d79", {"titleProtectFlag": "0"})


def test_cancelling_a_job_stops_after_the_current_item(client):
    x = client.bridge.recorder.xsrs
    t0 = datetime(2026, 9, 1, 21, 0, tzinfo=JST)
    x.extra_titles = [make_title(f"0x{i:x}", f"番組{i}", t0 + timedelta(days=i)) for i in range(10, 16)]
    x.delay = 0.05
    ids = [t.id for t in x.extra_titles]
    job = client.post("/api/v1/titles/delete", headers=H, json={"ids": ids}).json()
    time.sleep(0.12)
    r = client.post(f"/api/v1/jobs/{job['id']}/cancel", headers=H).json()
    assert r["cancelled"] is True
    r = wait_job(client, job["id"])
    assert r["cancelled"] and r["finished"] and 0 < r["done"] < len(ids) and r["error"] is None
    assert r["result"]["deleted"] == ids[:r["done"]] and x.deleted == set(ids[:r["done"]])
    assert client.post(f"/api/v1/jobs/{job['id']}/cancel", headers=H).json()["done"] == r["done"]  # cancelling twice is harmless


def test_job_list_shows_running_then_finished(client):
    x = client.bridge.recorder.xsrs
    x.delay = 0.05
    running = client.post("/api/v1/titles/delete", headers=H, json={"ids": ["0x0000010000034d7a"]}).json()
    listed = client.get("/api/v1/jobs", headers=H).json()
    assert listed[0]["id"] == running["id"] and listed[0]["finished"] is False
    wait_job(client, running["id"])
    listed = client.get("/api/v1/jobs", headers=H).json()
    assert listed[0]["id"] == running["id"] and listed[0]["finished"] is True


def test_bulk_delete_skips_a_title_the_recorder_did_not_answer_for(client, monkeypatch):
    x = client.bridge.recorder.xsrs
    real = x.delete_title

    async def flaky(title_id):
        if title_id == "0x0000010000034d78":
            raise httpx.ReadTimeout("")
        await real(title_id)

    monkeypatch.setattr(x, "delete_title", flaky)
    job = client.post("/api/v1/titles/delete", headers=H, json={"ids": ["0x0000010000034d78", "0x0000010000034d7b"]}).json()
    r = wait_job(client, job["id"])
    assert r["error"] is None and r["result"]["deleted"] == ["0x0000010000034d7b"]
    assert r["result"]["skipped"] == [{"id": "0x0000010000034d78", "reason": "ReadTimeout"}]


def test_job_failure_names_a_silent_exception(client, monkeypatch):
    async def gone():
        raise TimeoutError  # str() of this is empty

    monkeypatch.setattr(client.bridge.recorder.xsrs, "list_titles_all", gone)
    client.bridge.titles_cache = None
    job = client.post("/api/v1/titles/delete", headers=H, json={"ids": ["0x0000010000034d78"]}).json()
    assert wait_job(client, job["id"])["error"] == "TimeoutError"
