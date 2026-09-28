import re
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

import pytest

from bdzbridge.recorder.epg import JST
from bdzbridge.recorder.xsrs import (
    XsrsError,
    build_create_elements,
    build_recorder_rule_elements,
    build_update_elements,
    parse_recorder_rule,
    parse_reservation,
)
from tests.conftest import recorder_answering, soap_answer

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


def test_parse_title_reads_genre_code():
    import xml.etree.ElementTree as ET

    from bdzbridge.recorder.xsrs import parse_title

    item = ET.fromstring('<item id="0x0000010000034d78"><title>t</title><scheduledStartDateTime>2026-09-13T21:00:00+0900'
                         '</scheduledStartDateTime><scheduledDuration>60</scheduledDuration>'
                         '<scheduledChannelID broadcastingType="2" channelType="2">0x0418</scheduledChannelID>'
                         '<desiredQualityMode>230</desiredQualityMode><genreID type="2">168</genreID>'
                         '<lastPlaybackTime resumePoint="13">2026-09-14T01:03:50+0900</lastPlaybackTime></item>')
    t = parse_title(item)
    assert t.genre_code == 168 and t.resume_sec == 13 and t.last_played.hour == 1


def test_title_update_elements_carry_only_the_changes():
    from bdzbridge.recorder.xsrs import build_title_update_elements

    el = build_title_update_elements("0x0000010000034d78", protected=True)
    assert el == ('<xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/"><item id="0x0000010000034d78">'
                  "<titleProtectFlag>1</titleProtectFlag></item></xsrs>")
    assert "<title>a &amp; b</title><titleNewFlag>0</titleNewFlag>" in build_title_update_elements("0x1", title="a & b", is_new=False)


def test_parse_title_never_played():
    import xml.etree.ElementTree as ET

    from bdzbridge.recorder.xsrs import parse_title

    item = ET.fromstring('<item id="0x1"><title>t</title><scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>'
                         '<scheduledDuration>60</scheduledDuration><lastPlaybackTime resumePoint="0">notplayed</lastPlaybackTime></item>')
    t = parse_title(item)
    assert t.last_played is None and t.resume_sec == 0


# what a BDZ-FBT4100 answered for one condition set up on its own screen, and what it accepted from the LAN
RULE_XML = ('<object type="SEARCH" id="0x0000470f"><desiredQualityMode>220</desiredQualityMode>'
            '<recordDestinationID>HDD</recordDestinationID><searchSetting type="MULTIPLE" logic="AND">'
            '<name>クイズ/サンプル/テスト</name><genreID type="2">0x50</genreID><keyword>サンプル</keyword>'
            '<keyword>テスト</keyword><excludeKeyword>ダミー</excludeKeyword><timeScope>NIGHT</timeScope>'
            '<broadcastTypeScope>TRD</broadcastTypeScope></searchSetting></object>')


def test_parse_recorder_rule_reads_the_hex_genre_and_both_keyword_lists():
    r = parse_recorder_rule(ET.fromstring(RULE_XML))
    assert r.id == "0x0000470f" and r.name == "クイズ/サンプル/テスト"
    assert r.keywords == ["サンプル", "テスト"] and r.excluded == ["ダミー"] and r.logic == "AND"
    assert (r.genre_level1, r.genre_level2) == (5, 0) and r.time_scope == "NIGHT" and r.broadcasting_scope == "TRD"
    assert r.quality_code == 220 and r.quality_code_4k is None and r.destination == "HDD"


def test_recorder_rule_elements_follow_the_recorders_own_order():
    # keyword only, scopes wide open, as went through X_CreatePrefRecSetting on the real recorder -- plus the
    # quality for the 4K waves, after the ordinary one as the recorder lists them, without which they get DR
    assert build_recorder_rule_elements(keywords=["サンプル"], quality_code=220) == (
        '<xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/"><object type="SEARCH">'
        '<desiredQualityMode>220</desiredQualityMode><desiredQualityModeForAdvanced>220</desiredQualityModeForAdvanced>'
        '<recordDestinationID>HDD</recordDestinationID>'
        '<searchSetting type="MULTIPLE" logic="OR"><name>サンプル</name><keyword>サンプル</keyword>'
        '<timeScope>ALL</timeScope><broadcastTypeScope>ALL</broadcastTypeScope></searchSetting></object></xsrs>')
    # everything at once: the genre in hex before the keywords, exclusions after, text escaped
    assert build_recorder_rule_elements(keywords=["a & b", "c"], excluded=["x"], logic="AND", genre_level1=3, genre_level2=0,
                                        time_scope="NIGHT", broadcasting_scope="TRD", quality_code=230) == (
        '<xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/"><object type="SEARCH">'
        '<desiredQualityMode>230</desiredQualityMode><recordDestinationID>HDD</recordDestinationID>'
        '<searchSetting type="MULTIPLE" logic="AND"><name>a &amp; b</name><genreID type="2">0x30</genreID>'
        '<keyword>a &amp; b</keyword><keyword>c</keyword><excludeKeyword>x</excludeKeyword>'
        '<timeScope>NIGHT</timeScope><broadcastTypeScope>TRD</broadcastTypeScope></searchSetting></object></xsrs>')


def test_a_whole_genre_is_the_recorders_starred_form():
    # what a BDZ-FBT4100 wrote for a condition set up on its screen as バラエティ with no sub-genre, and no keyword
    obj = ET.fromstring('<object type="SEARCH" id="0x00021703"><searchSetting type="MULTIPLE" logic="OR">'
                        '<name>バラエティ</name><genreID type="3">0x5*</genreID><timeScope>MORNING</timeScope>'
                        '<broadcastTypeScope>BSD</broadcastTypeScope></searchSetting></object>')
    r = parse_recorder_rule(obj)
    assert (r.genre_level1, r.genre_level2) == (5, None) and r.keywords == [] and r.quality_code is None
    assert r.time_scope == "MORNING" and r.broadcasting_scope == "BSD"
    assert '<genreID type="3">0x5*</genreID>' in build_recorder_rule_elements(keywords=[], genre_level1=5, quality_code=220)
    assert '<genreID type="2">0x50</genreID>' in build_recorder_rule_elements(keywords=[], genre_level1=5, genre_level2=0, quality_code=220)


def test_a_4k_condition_puts_its_quality_in_the_advanced_element():
    # the recorder keeps a quality per wave and drops desiredQualityMode for a 4K-only condition (measured)
    four_k = build_recorder_rule_elements(keywords=["x"], broadcasting_scope="ADVBSD", quality_code=220)
    assert '<desiredQualityModeForAdvanced>220</desiredQualityModeForAdvanced>' in four_k
    assert '<desiredQualityMode>' not in four_k
    bs = build_recorder_rule_elements(keywords=["x"], broadcasting_scope="BSD", quality_code=220)
    assert '<desiredQualityMode>220</desiredQualityMode>' in bs and 'ForAdvanced' not in bs
    # every wave: given desiredQualityMode alone, the recorder fills the 4K side in as DR (measured), so both
    every = build_recorder_rule_elements(keywords=["x"], broadcasting_scope="ALL", quality_code=240)
    assert ('<desiredQualityMode>240</desiredQualityMode><desiredQualityModeForAdvanced>240'
            '</desiredQualityModeForAdvanced>') in every
    # and a scope the recorder does not know, which it widens to ALL (measured with NOSUCHWAVE)
    unknown = build_recorder_rule_elements(keywords=["x"], broadcasting_scope="NOSUCHWAVE", quality_code=240)
    assert ('<desiredQualityMode>240</desiredQualityMode><desiredQualityModeForAdvanced>240'
            '</desiredQualityModeForAdvanced>') in unknown
    # what the box wrote for a BS4K condition at 深夜: no ordinary quality at all
    obj = ET.fromstring('<object type="SEARCH" id="0x0002470e">'
                        '<desiredQualityModeForAdvanced>100</desiredQualityModeForAdvanced>'
                        '<recordDestinationID>HDD</recordDestinationID>'
                        '<searchSetting type="MULTIPLE" logic="OR"><name>x</name><genreID type="3">0x5*</genreID>'
                        '<timeScope>MIDNIGHT</timeScope><broadcastTypeScope>ADVBSD</broadcastTypeScope>'
                        '</searchSetting></object>')
    r = parse_recorder_rule(obj)
    assert r.quality_code is None and r.quality_code_4k == 100
    assert r.time_scope == "MIDNIGHT" and r.broadcasting_scope == "ADVBSD"


async def test_an_answer_that_is_not_xml_is_an_xsrs_error():
    # a busy recorder's 503 carries no SOAP, and nor does an empty body; both raised a ParseError that no caller catches
    answers = {"X_GetRecordScheduleList": (503, "Service Unavailable"),
               "X_DeleteRecordSchedule": (200, ""),
               "X_GetConflictList": (200, soap_answer("X_GetConflictList", "<Result>&lt;DIDL-Lite</Result>"))}
    x = recorder_answering(lambda action: answers[action])
    with pytest.raises(XsrsError) as busy:
        await x.list_reservations()
    assert busy.value.busy and busy.value.explanation.endswith("(503: X_GetRecordScheduleList)")
    with pytest.raises(XsrsError) as empty:
        await x.delete_reservation("0x1")
    assert not empty.value.busy and empty.value.explanation == "レコーダーの応答を読み取れませんでした (X_DeleteRecordSchedule)"
    with pytest.raises(XsrsError) as garbled:  # the list inside a well-formed answer, parsed on its own
        await x.conflicts("<xsrs/>")
    assert (garbled.value.status, garbled.value.code, garbled.value.action) == (200, None, "X_GetConflictList")
    await x.http.aclose()
