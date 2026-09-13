import re
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

from recbridge.recorder.epg import JST
from recbridge.recorder.xsrs import build_create_elements, build_update_elements, parse_reservation

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def test_create_elements_match_official_app():
    captured = (FIXTURES / "create-request.xml").read_text()
    expected = re.search(r"<xsrs .*?</xsrs>", captured, re.DOTALL).group(0)
    got = build_create_elements(title="テスト番組　第１回[字]", start=datetime(2026, 9, 17, 21, 0, tzinfo=JST),
                                duration_sec=3600, repeat_code="1", broadcasting_type=2, service_id=0x428,
                                quality_code=240, event_id=0x311f)
    assert got == expected


def test_create_elements_without_event_id():
    el = build_create_elements(title="x", start=datetime(2026, 9, 14, 4, 0, tzinfo=JST), duration_sec=300,
                               repeat_code="w15", broadcasting_type=3, service_id=101, quality_code=230)
    assert "desiredMatchingID" not in el and "<scheduledConditionID>w15</scheduledConditionID>" in el
    assert 'broadcastingType="3" channelType="2">0x0065<' in el and "+09:00" in el


def test_parse_reservation_sample():
    item = ET.fromstring((FIXTURES / "schedule-item.xml").read_text())
    r = parse_reservation(item)
    assert r.id == "0x00000000000a9432" and r.title.startswith("サンプル番組")
    assert r.start.isoformat() == "2026-09-13T20:00:00+09:00" and r.duration_sec == 2700
    assert r.repeat_code == "w7" and r.broadcasting_type == 2 and r.service_id == 0x400 and r.event_id == 0x3798
    assert r.quality_code == 230 and not r.recording and not r.conflict and r.creator == "2200"


def test_update_elements_carry_the_id():
    el = build_update_elements("0x00000000000d357d", title="x", start=datetime(2026, 9, 15, 4, 0, tzinfo=JST), duration_sec=300,
                               repeat_code="1", broadcasting_type=2, service_id=0x400, quality_code=250)
    assert el.startswith('<xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/"><item id="0x00000000000d357d">')
