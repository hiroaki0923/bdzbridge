import os
from pathlib import Path

import pytest

from bdzbridge.recorder import epg as epgmod
from bdzbridge.recorder.epg import decode_epg_file, encode_epg_file, encode_service, parse_service

REAL = Path(os.environ.get("BDZBRIDGE_TEST_EPG_FILE", "tests/fixtures/EPG_TRDEPG_FILE.dat"))


def test_roundtrip(services):
    out = decode_epg_file(encode_epg_file(services))
    assert [s.service_id for s in out] == [1024, 1025]
    assert out[0].name == "ＮＨＫ総合１・東京"
    a = out[0].programs[0]
    assert (a.event_id, a.title, a.description, a.extended) == (14792, "サンプルニュース　あさの放送", "朝のニュース", "詳細テキスト")
    assert a.start.isoformat() == "2026-09-14T05:00:00+09:00" and a.duration_sec == 3600
    assert a.genres == [(0, 0), (0, 1)] and a.copy_control == 2 and a.parental_rating == 0
    assert len(out[0].programs) == 4  # two @DAY blocks
    ref = out[1].programs[0]
    assert ref.is_reference and (ref.ref_service_id, ref.ref_event_id) == (1024, 14792)


def test_service_record_layout(services):
    rec = encode_service(services[0])
    assert rec[:4] == b"@SRV" and rec[156:160] == b"@DAY"
    assert parse_service(rec).service_id == 1024


@pytest.mark.skipif(not REAL.exists(), reason="set BDZBRIDGE_TEST_EPG_FILE to a captured EPG_TRDEPG_FILE.dat")
def test_real_file_decodes():
    out = decode_epg_file(REAL.read_bytes())
    nhk = next(s for s in out if s.service_id == 1024)
    ev = {p.event_id: p for p in nhk.programs}
    assert 14232 in ev and ev[14232].start.isoformat() == "2026-09-13T20:00:00+09:00"


def test_clean_maps_arib_symbols():
    from bdzbridge.recorder.epg import _clean
    assert _clean("ニュース\x00\x00".encode()) == "ニュース[字][手]"
    assert _clean("謎の記号".encode()) == "謎の記号"


def test_clean_spells_out_broadcast_symbols():
    assert epgmod._clean("\U0001f19e\U0001f1a7ニュース[字]".encode()) == "[4K][HDR]ニュース[字]"
