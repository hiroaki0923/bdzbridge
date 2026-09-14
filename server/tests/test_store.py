from datetime import datetime, timedelta

from bdzbridge.recorder.epg import JST
from bdzbridge.store import Store
from tests.conftest import make_services


def _store(tmp_path):
    s = Store(str(tmp_path / "s.sqlite3"))
    s.replace_services("td", make_services())
    return s


def test_rule_matches_respect_since_and_title_only(tmp_path):
    s = _store(tmp_path)
    day = datetime(2026, 9, 14, 5, 0, tzinfo=JST)
    rule = s.add_rule("ニュース", None, None, True, "LSR")
    assert [p.event_id for p in s.rule_matches(rule, since=day - timedelta(hours=1))] == [14792]
    assert s.rule_matches(rule, since=day + timedelta(minutes=1)) == []  # already started
    wide = s.add_rule("生活情報", None, None, False, "LSR")
    assert [p.event_id for p in s.rule_matches(wide, since=day)] == [14793]
    assert s.rule_matches(s.add_rule("生活情報", None, None, True, "LSR"), since=day) == []


def test_auto_log_is_per_rule_and_deleted_with_it(tmp_path):
    s = _store(tmp_path)
    r1, r2 = s.add_rule("a", None, None, True, "LSR"), s.add_rule("b", None, None, True, "LSR")
    p = s.programs(bt="td", service_id=1024)[0]
    s.auto_log_add(r1["id"], p, "reserved")
    assert s.auto_logged(r1["id"], "td", 1024, p.event_id) and not s.auto_logged(r2["id"], "td", 1024, p.event_id)
    assert s.auto_log()[0]["rule_query"] == "a"
    assert s.delete_rule(r1["id"]) and s.auto_log() == [] and not s.delete_rule(r1["id"])


def test_channel_prefs_survive_an_epg_reload(tmp_path):
    s = _store(tmp_path)
    s.set_channel_prefs("td", order=[1025, 1024], hidden=[1024])
    s.replace_services("td", make_services())  # a refresh rewrites the channel table
    assert [c["service_id"] for c in s.channels("td", include_hidden=True)] == [1025, 1024]
    assert [c["service_id"] for c in s.channels("td")] == [1025]


def test_title_summary_cache(tmp_path):
    s = _store(tmp_path)
    assert s.title_summary("0x1") is None
    s.set_title_summary("0x1", "")
    assert s.title_summary("0x1") == ""  # an empty answer is remembered too, so the recorder is not asked again
