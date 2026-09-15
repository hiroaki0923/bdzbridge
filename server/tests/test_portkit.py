import json

from bdzbridge.tools import portkit


def test_port_vectors_are_up_to_date():
    """docs/port/* are generated; regenerate with `uv run python -m bdzbridge.tools.portkit`."""
    stale = [p.name for p, data in portkit.files().items() if not p.exists() or p.read_bytes() != data]
    assert not stale, f"stale: {stale} - run `uv run python -m bdzbridge.tools.portkit`"


def test_port_vectors_round_trip():
    out = portkit.files()
    xsrs = json.loads(out[portkit.OUT / "xsrs.json"])
    assert xsrs["create_elements"][0]["elements"].endswith("</item></xsrs>") and "+09:00" in xsrs["create_elements"][0]["elements"]
    assert "&lt;z&gt;" in xsrs["create_elements"][1]["elements"] and "desiredMatchingID" not in xsrs["create_elements"][1]["elements"]
    assert xsrs["parse_title"][1]["expected"]["last_played"] is None
    epg = json.loads(out[portkit.OUT / "epg-sample.json"])
    assert epg["services"][1]["programs"][0]["reference"] and epg["services"][0]["programs"][0]["title"] == "サンプルニュース　あさの放送[字]"
    series = json.loads(out[portkit.OUT / "series.json"])
    by_title = {c["title"]: c for c in series["titles"]}
    assert by_title["日曜劇場「SAMPLE」 第1話"]["series_key"] == by_title["日曜劇場「ＳＡＭＰＬＥ」第１８話　前半戦完結　主人公＆相棒"]["series_key"]
