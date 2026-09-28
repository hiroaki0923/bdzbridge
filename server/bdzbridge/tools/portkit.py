"""Write docs/port/: language-neutral conformance vectors for a port of the recorder-facing code (a native app).

    uv run python -m bdzbridge.tools.portkit          # rewrite the files
    uv run python -m bdzbridge.tools.portkit --check  # exit 1 when the checked-in files are stale (used by the tests)

Every vector is produced by the Python implementation that talks to the real recorder, so a port that reproduces
them byte for byte (the XSRS payloads) or value for value (decoders, heuristics) behaves the same way. The
files are described in docs/porting.md.
"""
from __future__ import annotations

import base64
import hashlib
import json
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
from dataclasses import asdict
from datetime import datetime, timedelta
from pathlib import Path

from ..api.serializers import title_out
from ..recorder import codes, discovery
from ..recorder.epg import ARIB_SYMBOLS, JST, Program, Service, decode_epg_file, encode_epg_file
from ..recorder.logo import LOGO_CLUT, decode_logo_file, encode_logo_file
from ..recorder.series import same_title_key, series_key, series_name, summary_key
from ..recorder.xsrs import RecordedTitle as XTitle
from ..recorder.xsrs import (
    _objects,
    _soap_body,
    build_create_elements,
    build_recorder_rule_elements,
    build_title_update_elements,
    build_update_elements,
    parse_recorder_rule,
    parse_reservation,
    parse_title,
)
from ..services.titles import duplicate_candidates, duplicate_sets, fixed_blurbs, group_titles

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "docs" / "port"
FIXTURES = ROOT / "server" / "tests" / "fixtures"

# Titles seen on a real recorder (and a few synthetic ones) that exercise every rule of the grouping heuristic.
SERIES_TITLES = [
    "日曜劇場「ＳＡＭＰＬＥ」第１８話　前半戦完結　主人公＆相棒", "架空兄弟！（３５）弟の誕生",
    "名探偵サンプル！　＃３３ 名探偵の道も一歩から", "冒険者サンプルの旅（２３）「王の中の王」",
    "[字]サンプルといっしょ　月曜日", "記録サンプル７２分ＰＲ", "必殺サンプル人Ⅳ　第１４話「主人公節分の豆を食べる」",
    "サンプル・パトロール「ピカピカパーティーでプカプカピンチ！」", "アニメ　サンプルなおさる「こんがら交換」「みどり、あお」",
    "【土曜ドラマ】覚えのない事件　後編「迷宮」", "サンプルえもん　【夢ホール】【ねこっかぶり】",
    "サンプルしんちゃん　【ホットケーキはホッとするゾ】", "サンプルスイッチ▽フレーミーとたね　▽たこたこピー",
    "サンプルスイッチ「この装置　こんな名前がついてましたＳＰ」", "それいけ！サンプルマン「カップケーキちゃんとふでじいさん・他」",
    "刑事サンプル（４８）「幻の宝（たから）石」", "ＳａｍｐｌｅＢｕｓーサンプルバスー　★大人気の知育アニメがテレビで登場！",
    "司会者・研究者の！？ＰＲ　人類史３．０　人間とは何か", "土曜ドラマ「サンプル三ツ星」２分ＰＲ　今後の見どころ紹介！",
    "【土曜ドラマ】峠越え　後編", "サンプルで会いましょう！（２５）自律神経　最新研究",
    "新プロジェクトＸ「世紀の難工事　架空国際空港」", "サンプル高校講座　数学Ⅰ　２次不等式[字]", "サンプルぷしゅ",
    "＃１２　いきなり話数で始まる", "日曜劇場「SAMPLE」 第1話", "サンプルニュース　あさの放送[字]", "サンプルニュース　あさの放送",
    "ドラマＡ　第３話[再]", "ドラマA 第3話", "ドラマＡ　第４話", "大河ドラマ「架空記」（３６）",
    "映画「サンプル物語」", "連続テレビ小説　空、晴れる（１２１）第２５週「空」", "３分サンプル料理", "",
    "サンプル野球　第３戦　架空対架空", "大相撲サンプル場所　１０日目", "サンプル選手権　決勝", "サンプル杯　準決勝　第２試合",
    "サンプルの秘密　その３", "【HV】サンプル紀行＜再＞", "サンプル劇場（後）", "サンプル初日の出中継", "サンプル講座　初回スペシャル",
    "サンプルゴルフ女子▼架空杯争奪第４戦", "サンプル台所　Ｓｅａｓｏｎ２[終]▼最終話「南瓜」",
]
SUMMARIES = ["（再放送）あらすじ　本文", "あらすじ本文[再]", "", "ドラマ[字]の　あらすじ。"]


def _sample_services() -> list[Service]:
    day = datetime(2026, 9, 14, 5, 0, tzinfo=JST)
    nhk = Service(1024, "ＮＨＫ総合１・東京", [
        Program(1024, 14792, day, day + timedelta(hours=1), "サンプルニュース　あさの放送[字]", "朝のニュース", "詳細テキスト",
                genres=[(0, 0), (0, 1)], copy_control=2, parental_rating=0),
        Program(1024, 14793, day + timedelta(hours=1), day + timedelta(hours=1, minutes=15), "あさのサンプル", "生活情報", "",
                genres=[(2, 4)]),
        Program(1024, 14800, day + timedelta(days=1, hours=15), day + timedelta(days=1, hours=16), "翌日の番組", "", "x",
                genres=[(3, 0)], copy_control=1, parental_rating=2),
        Program(1024, 14794, day + timedelta(hours=16), day + timedelta(hours=17), "日曜劇場「ＳＡＭＰＬＥ」", "", ""),
    ])
    sub = Service(1025, "ＮＨＫ総合２・東京", [
        Program(1025, 14792, day, day + timedelta(hours=1), ref_service_id=1024, ref_event_id=14792),
    ])
    return [nhk, sub]


def _program_dict(p: Program) -> dict:
    d = {"service_id": p.service_id, "event_id": p.event_id, "start": p.start.isoformat(), "end": p.end.isoformat(),
         "duration_sec": p.duration_sec}
    if p.is_reference:
        d.update({"reference": True, "ref_service_id": p.ref_service_id, "ref_event_id": p.ref_event_id})
    else:
        d.update({"title": p.title, "description": p.description, "extended": p.extended,
                  "genres": [list(g) for g in p.genres], "copy_control": p.copy_control, "parental_rating": p.parental_rating})
    return d


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def _logo_png(index: int, width: int = 64, height: int = 36) -> bytes:
    """A palette PNG without PLTE, as stored by the recorder: every pixel is colour `index`."""
    rows = b"".join(b"\x00" + bytes([index]) * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0))
            + _png_chunk(b"IDAT", zlib.compress(rows)) + _png_chunk(b"IEND", b""))


def _sample_titles() -> list[XTitle]:
    """Recordings that exercise the derived bits: the watch states, and the name a group ends up showing.

    Full-width and half-width spellings of one programme share a grouping key but not a display name, so the
    group has to pick between them: the commonest wins, and the first one seen wins a tie.
    """
    base = datetime(2026, 9, 1, 21, 0, tzinfo=JST)

    def title(tid: str, name: str, offset: timedelta, **kw) -> XTitle:
        args = {"id": tid, "title": name, "start": base + offset, "duration_sec": 1800, "broadcasting_type": 2,
                "service_id": 1024, "quality_code": 230, "protected": False, "is_new": True,
                "destination": "HDD", "size_mb": 1000, "genre_code": 0x30}
        args.update(kw)
        return XTitle(**args)

    return [
        # one programme, three episodes, two spellings: ＡＢＣ twice and ABC once
        title("0x1", "ドラマＡＢＣ　第１話", timedelta()),
        title("0x2", "ドラマABC 第2話", timedelta(days=1), is_new=False, resume_sec=600, size_mb=1200),
        title("0x3", "ドラマＡＢＣ　第３話", timedelta(days=2), is_new=False, protected=True, size_mb=900),
        # a tie between two spellings: the first one seen is the one shown
        title("0x4", "ニュース７[字]", timedelta(days=3), genre_code=0x00),
        title("0x5", "ニュース7", timedelta(days=4), is_new=False, genre_code=0x00),
        # its own group, never played, and one that was played to the end
        title("0x6", "アニメ　サンプルなおさる「こんがら交換」", timedelta(days=5), genre_code=0x71, size_mb=500),
        title("0x7", "映画「サンプル物語」", timedelta(days=6), is_new=False, resume_sec=0, genre_code=0x60,
              size_mb=4000),
    ]


def _duplicate_titles() -> tuple[list[XTitle], dict[str, str]]:
    """Copies of one broadcast, and what the recorder says each of them is about.

    0xf1/0xf2 are the same programme twice, the second still being recorded, which is the copy kept.
    0xd1/0xd2/0xd3 are the same episode three times: the first two share their programme text, the third has
    a different one and so is a set of its own. 0xd4 has the same title but runs half an hour longer, so it is
    not a copy at all. 0xe1/0xe2 have no text, which leaves only the title and the length to go on.
    0xb1/0xb2 are a daily show whose text the guide repeats from one day to the next (_duplicate_guide), and
    0xa1/0xa2 a mini anime whose text is too short to tell one episode from another: both agree on their text
    without that saying they are the same broadcast.
    """
    base = datetime(2026, 9, 1, 21, 0, tzinfo=JST)

    def title(tid: str, name: str, offset: timedelta, duration: int = 3600, **kw) -> XTitle:
        args = {"id": tid, "title": name, "start": base + offset, "duration_sec": duration,
                "broadcasting_type": 2, "service_id": 1024, "quality_code": 230, "protected": False,
                "is_new": True, "destination": "HDD", "size_mb": 2000, "genre_code": 0x30}
        args.update(kw)
        return XTitle(**args)

    titles = [
        title("0xd1", "刑事サンプル（４８）「幻の宝石」", timedelta()),
        # the same episode, re-run a week later, one minute shorter and in a worse mode
        title("0xd2", "刑事サンプル（48）「幻の宝石」[再]", timedelta(days=7), duration=3540,
              quality_code=240, is_new=False, resume_sec=300),
        title("0xd3", "刑事サンプル（４８）「幻の宝石」", timedelta(days=14), duration=3600, protected=True),
        title("0xd4", "刑事サンプル（４８）「幻の宝石」", timedelta(days=21), duration=5400),
        title("0xe1", "名もなき番組", timedelta(days=1), duration=1800, size_mb=500),
        title("0xe2", "名もなき番組", timedelta(days=2), duration=1800, size_mb=500),
        # the same programme twice more, the second still being recorded: the recorder refuses to delete
        # one in progress, so it is the copy to keep and is never offered up
        title("0xf1", "サンプル特番「今夜の生放送」", timedelta(days=3), duration=1800, size_mb=900),
        title("0xf2", "サンプル特番「今夜の生放送」", timedelta(days=10), duration=1800, size_mb=900,
              recording=True),
        # the same text every morning, which the guide shows on two days; the title's mark does not matter
        title("0xb1", "サンプル体操[字]", timedelta(days=4), duration=180, size_mb=60),
        title("0xb2", "サンプル体操", timedelta(days=5), duration=180, size_mb=60),
        # a one-line text, under twenty characters, with nothing in the guide to go on
        title("0xa1", "ミニアニメ　サンプルくん", timedelta(days=4), duration=300, size_mb=100),
        title("0xa2", "ミニアニメ　サンプルくん", timedelta(days=6), duration=300, size_mb=100),
    ]
    summaries = {
        "0xd1": "架空市警のサンプル警部が、消えた宝石の行方を追って港町へ向かう。",
        "0xd2": "（再放送）架空市警のサンプル警部が、消えた宝石の行方を追って港町へ向かう。",
        "0xd3": "まったく別のあらすじ。",
        "0xd4": "拡大版のあらすじ。",
        "0xe1": "",
        "0xe2": "",
        "0xf1": "今夜の生放送は、架空の町の夏祭りから中継でお届けします。",
        "0xf2": "今夜の生放送は、架空の町の夏祭りから中継でお届けします。",
        "0xb1": FIXED_BLURB,
        "0xb2": FIXED_BLURB,
        "0xa1": "サンプルくんの毎日。",
        "0xa2": "サンプルくんの毎日。",
    }
    return titles, summaries


FIXED_BLURB = "体を動かすサンプル体操。今日も元気に、腕を大きく回しましょう。"


def _duplicate_guide() -> list[tuple[str, str, datetime]]:
    """The guide the duplicate sets are read against: (title, description, start) for each programme.

    サンプル体操 has the same text on two broadcast days, spelled with and without its mark, so its text is a
    fixed one. 深夜のサンプル has its text twice as well, but either side of midnight on one broadcast day, which
    is a showing again the same night rather than a text used every day. 刑事サンプル's episode is in it once,
    and again a day later with a different text: neither makes its text a fixed one.
    """
    def at(day: int, hour: int, minute: int = 0) -> datetime:
        return datetime(2026, 9, day, hour, minute, tzinfo=JST)

    night = "深夜に届ける架空のサンプル番組、今夜のテーマは旅と音楽。"
    detective = "架空市警のサンプル警部が、消えた宝石の行方を追って港町へ向かう。"
    return [
        ("サンプル体操[字]", FIXED_BLURB, at(14, 6)),
        ("サンプル体操", FIXED_BLURB, at(15, 6)),
        ("深夜のサンプル", night, at(14, 23, 30)),
        ("深夜のサンプル", night, at(15, 1, 30)),
        ("刑事サンプル（４８）「幻の宝石」", detective, at(16, 21)),
        ("刑事サンプル（４８）「幻の宝石」", "拡大版のあらすじ。", at(17, 21)),
        ("サンプル特番「今夜の生放送」", "", at(18, 20)),
    ]


def duplicates_vectors() -> dict:
    titles, summaries = _duplicate_titles()
    guide = _duplicate_guide()
    fixed = fixed_blurbs(guide)
    candidates = duplicate_candidates(titles)

    def set_dict(s: dict) -> dict:
        return {"title": s["title"], "confidence": s["confidence"], "size_mb": s["size_mb"],
                "keep": s["keep"], "suggest_delete": s["suggest_delete"], "reasons": s["reasons"],
                "items": [i["id"] for i in s["items"]]}

    return {
        "note": "candidates are grouped by title and then by length within 120 seconds of each other; the "
                "programme text splits them further. reasons say why each recording is kept or offered up. "
                "A set whose text is under 20 characters (summary_key), or whose title and text the guide shows "
                "on two or more broadcast days (04:00 to 04:00 JST; fixed_blurbs, from guide), is boilerplate "
                "rather than high.",
        "titles": [{"id": t.id, "title": t.title, "start": t.start.isoformat(),
                    "duration_sec": t.duration_sec, "quality_code": t.quality_code, "protected": t.protected,
                    "is_new": t.is_new, "recording": t.recording, "resume_sec": t.resume_sec,
                    "size_mb": t.size_mb, "summary": summaries[t.id]} for t in titles],
        "guide": [{"title": title, "summary": summary, "start": start.isoformat()} for title, summary, start in guide],
        "fixed_blurbs": [{"same_title_key": tk, "summary_key": sk} for tk, sk in sorted(fixed)],
        "candidates": [[t.id for t in group] for group in candidates],
        "sets": [set_dict(s) for s in duplicate_sets(candidates, summaries, fixed=fixed)],
    }


def titles_vectors() -> dict:
    titles = _sample_titles()

    def group_dict(g) -> dict:
        return {"key": g.key, "name": g.name, "count": g.count, "size_mb": g.size_mb,
                "latest": g.latest.isoformat(), "earliest": g.earliest.isoformat(),
                "protected_count": g.protected_count, "new_count": g.new_count}

    return {
        "note": "watch_state, the grouping key and the group a recording lands in, all derived from the "
                "recorder's own fields. genre_code is the ARIB nibbles as level1 * 16 + level2.",
        "titles": [{"id": t.id, "title": t.title, "start": t.start.isoformat(), "duration_sec": t.duration_sec,
                    "protected": t.protected, "is_new": t.is_new, "size_mb": t.size_mb,
                    "genre_code": t.genre_code, "resume_sec": t.resume_sec,
                    "expected": {"watch_state": title_out(t).watch_state, "series_key": series_key(t.title),
                                 "series_name": series_name(t.title)}}
                   for t in titles],
        "groups": [group_dict(g) for g in group_titles(titles)],
        "groups_drama_only": {"genre": 3, "groups": [group_dict(g) for g in group_titles(titles, genre=3)]},
        "duplicates": duplicates_vectors(),
    }


def codes_vectors() -> dict:
    return {
        "broadcasting": codes.BROADCASTING, "broadcasting_label": codes.BROADCASTING_LABEL,
        "epg_files": codes.EPG_FILES, "logo_files": codes.LOGO_FILES,
        "quality": codes.QUALITY, "quality_elsewhere": codes.QUALITY_ELSEWHERE, "quality_label": codes.QUALITY_LABEL,
        "sub_genre_label": {f"{k:#x}": {f"{k2:#x}": v2 for k2, v2 in v.items()}
                            for k, v in codes.GENRE_LABEL2.items()},
        "rule_logic_label": codes.RULE_LOGIC_LABEL, "time_scope_label": codes.TIME_SCOPE_LABEL,
        "broadcasting_scope_label": codes.BROADCASTING_SCOPE_LABEL,
        "repeat": codes.REPEAT, "repeat_label": codes.REPEAT_LABEL, "weekday_repeat": codes.WEEKDAY_REPEAT,
        "genre_label": {f"{k:#x}": v for k, v in codes.GENRE_LABEL.items()},
        "arib_symbols": {f"U+{ord(k):04X}": v for k, v in ARIB_SYMBOLS.items()},
        "logo_clut": [list(c) for c in LOGO_CLUT],
        "ports": {"upnp": 64220, "stream_default": 60151, "ssdp": "239.255.255.250:1900"},
        "namespaces": {"xsrs_service": "urn:schemas-xsrs-org:service:X_ScheduledRecording:2",
                       "pvr_service": "urn:schemas-s-bras-org:service:X_PvrControl:1",
                       "cds_service": "urn:schemas-upnp-org:service:ContentDirectory:1",
                       "xsrs_metadata": "urn:schemas-xsrs-org:metadata-1-0/x_srs/"},
        "control_urls": {"xsrs": "/XSRS", "pvr": "/X_PvrControl", "cds": "/DMSContentDirectory"},
    }


def series_vectors() -> dict:
    return {
        "titles": [{"title": t, "series_name": series_name(t), "series_key": series_key(t), "same_title_key": same_title_key(t)}
                   for t in SERIES_TITLES],
        "summaries": [{"summary": s, "summary_key": summary_key(s)} for s in SUMMARIES],
    }


def xsrs_vectors() -> dict:
    t0 = datetime(2026, 9, 17, 21, 0, tzinfo=JST)
    create_cases = [
        {"name": "captured from the official app (tests/fixtures/create-request.xml)",
         "input": {"title": "テスト番組　第１回[字]", "start": t0.isoformat(), "duration_sec": 3600, "repeat_code": "1",
                   "broadcasting_type": 2, "service_id": 0x428, "quality_code": 240, "event_id": 0x311f}},
        {"name": "time-only reservation, weekday repeat, BS",
         "input": {"title": "x & y <z>", "start": datetime(2026, 9, 14, 4, 0, tzinfo=JST).isoformat(), "duration_sec": 300,
                   "repeat_code": "w15", "broadcasting_type": 3, "service_id": 101, "quality_code": 230, "event_id": None}},
    ]
    for c in create_cases:
        i = dict(c["input"])
        i["start"] = datetime.fromisoformat(i["start"])
        c["elements"] = build_create_elements(**i)
    update = dict(create_cases[1]["input"])
    update["start"] = datetime.fromisoformat(update["start"])
    reservation_item = (FIXTURES / "schedule-item.xml").read_text().strip()
    title_items = [
        ('<item id="0x0000010000034d78"><title>t</title><scheduledStartDateTime>2026-09-13T21:00:00+0900'
         '</scheduledStartDateTime><scheduledDuration>60</scheduledDuration>'
         '<scheduledChannelID broadcastingType="2" channelType="2">0x0418</scheduledChannelID>'
         '<desiredQualityMode>230</desiredQualityMode><genreID type="2">168</genreID><titleProtectFlag>1</titleProtectFlag>'
         '<titleNewFlag>0</titleNewFlag><recordSize>2048</recordSize>'
         '<lastPlaybackTime resumePoint="13">2026-09-14T01:03:50+0900</lastPlaybackTime></item>'),
        ('<item id="0x1"><title>never played</title><scheduledStartDateTime>2026-09-13T21:00:00+0900</scheduledStartDateTime>'
         '<scheduledDuration>60</scheduledDuration><lastPlaybackTime resumePoint="0">notplayed</lastPlaybackTime></item>'),
    ]

    def dt(v):
        return v.isoformat() if isinstance(v, datetime) else v

    # the recorder's own keyword conditions, as a BDZ-FBT4100 lists them: one set up on the box with everything
    # filled in, one made over the LAN with only a keyword (the recorder added the 4K quality itself)
    rule_objects = (
        '<object type="SEARCH" id="0x0000470f"><desiredQualityMode>220</desiredQualityMode>'
        '<recordDestinationID>HDD</recordDestinationID><searchSetting type="MULTIPLE" logic="AND">'
        '<name>クイズ/サンプル/テスト</name><genreID type="2">0x50</genreID><keyword>サンプル</keyword>'
        '<keyword>テスト</keyword><excludeKeyword>ダミー</excludeKeyword><timeScope>NIGHT</timeScope>'
        '<broadcastTypeScope>TRD</broadcastTypeScope></searchSetting></object>'
        '<object type="SEARCH" id="0x0000570b"><desiredQualityMode>220</desiredQualityMode>'
        '<desiredQualityModeForAdvanced>100</desiredQualityModeForAdvanced><recordDestinationID>HDD</recordDestinationID>'
        '<searchSetting type="MULTIPLE" logic="OR"><name>サンプル語</name><keyword>サンプル語</keyword>'
        '<timeScope>ALL</timeScope><broadcastTypeScope>ALL</broadcastTypeScope></searchSetting></object>'
        # the box's own: a whole genre and nothing else, on BS, in the morning (read with an empty Filter)
        '<object type="SEARCH" id="0x00021703"><searchSetting type="MULTIPLE" logic="OR"><name>バラエティ</name>'
        '<genreID type="3">0x5*</genreID><timeScope>MORNING</timeScope><broadcastTypeScope>BSD</broadcastTypeScope>'
        '</searchSetting></object>'
        # a 4K-only condition: the recorder sends the 4K quality and no ordinary one
        '<object type="SEARCH" id="0x0002470e"><desiredQualityModeForAdvanced>100</desiredQualityModeForAdvanced>'
        '<recordDestinationID>HDD</recordDestinationID><searchSetting type="MULTIPLE" logic="OR"><name>サンプル語</name>'
        '<keyword>サンプル語</keyword><timeScope>MIDNIGHT</timeScope><broadcastTypeScope>ADVBSD</broadcastTypeScope>'
        '</searchSetting></object>'
    )
    rule_list = f'<xsrs xmlns="urn:schemas-xsrs-org:metadata-1-0/x_srs/">{rule_objects}</xsrs>'
    rule_cases = [
        {"name": "keyword only on every wave: the quality goes in both elements, or the 4K waves get DR",
         "input": {"keywords": ["サンプル"], "quality_code": 220}},
        {"name": "every field: genre in hex before the keywords, exclusions after, text escaped",
         "input": {"keywords": ["a & b", "c"], "excluded": ["x"], "logic": "AND", "genre_level1": 3, "genre_level2": 0,
                   "time_scope": "NIGHT", "broadcasting_scope": "TRD", "quality_code": 230}},
        {"name": "a whole genre and no keyword, the recorder's starred form",
         "input": {"keywords": [], "genre_level1": 5, "time_scope": "MORNING", "broadcasting_scope": "BSD",
                   "quality_code": 220}},
        {"name": "a 4K wave, whose quality goes in the Advanced element instead",
         "input": {"keywords": ["x"], "time_scope": "MIDNIGHT", "broadcasting_scope": "ADVBSD", "quality_code": 220}},
        {"name": "a scope the recorder does not know, which it takes for ALL: the quality goes in both elements",
         "input": {"keywords": ["x"], "broadcasting_scope": "NOSUCHWAVE", "quality_code": 240}},
    ]
    for c in rule_cases:
        c["elements"] = build_recorder_rule_elements(**c["input"])

    return {
        "recorder_rules": {
            "note": "X_GetPrefRecSettingList with Filter \"*\" (an empty Filter drops the quality and the destination). "
                    "The channel narrowing the recorder's screen offers is never reported and is dropped when sent; "
                    "there is no update, only create and delete.",
            "list_result": rule_list,
            "parsed": [asdict(parse_recorder_rule(o)) for o in _objects(rule_list)],
            "create_elements": rule_cases,
        },
        "soap": {
            "note": "POST to control_url; headers Content-Type: text/xml; charset=\"utf-8\", Accept-Language: ja, "
                    "SOAPACTION: \"<service>#<action>\". Body exactly as below (no whitespace between elements).",
            "example": {"service": "urn:schemas-xsrs-org:service:X_ScheduledRecording:2", "action": "X_DeleteRecordSchedule",
                        "args": [["RecordScheduleID", "0x00000000000a9432"]],
                        "body": _soap_body("urn:schemas-xsrs-org:service:X_ScheduledRecording:2", "X_DeleteRecordSchedule",
                                           [("RecordScheduleID", "0x00000000000a9432")]).decode()},
        },
        "create_elements": create_cases,
        "update_elements": {"reservation_id": "0x00000000000d357d", "input": {k: dt(v) for k, v in update.items()},
                            "elements": build_update_elements("0x00000000000d357d", **update)},
        "title_update_elements": [
            {"input": {"title_id": "0x0000010000034d78", "protected": True},
             "elements": build_title_update_elements("0x0000010000034d78", protected=True)},
            {"input": {"title_id": "0x1", "title": "a & b", "is_new": False},
             "elements": build_title_update_elements("0x1", title="a & b", is_new=False)},
        ],
        "parse_reservation": {"item": reservation_item,
                              "expected": {k: dt(v) for k, v in asdict(parse_reservation(ET.fromstring(reservation_item))).items()}},
        "parse_title": [{"item": x, "expected": {k: dt(v) for k, v in asdict(parse_title(ET.fromstring(x))).items()}}
                        for x in title_items],
    }


def description_vectors() -> dict:
    xml = (FIXTURES / "description.xml").read_text()
    c = discovery.parse_description(xml, "192.0.2.10", 64220, "http://192.0.2.10:64220/description.xml", "scan")
    assert c is not None
    return {"description_xml": xml, "expected": asdict(c)}


def epg_vectors() -> tuple[bytes, dict]:
    services = _sample_services()
    raw = encode_epg_file(services)
    decoded = decode_epg_file(raw)
    return raw, {"file": "epg-sample.dat", "sha256": hashlib.sha256(raw).hexdigest(),
                 "services": [{"service_id": s.service_id, "name": s.name, "programs": [_program_dict(p) for p in s.programs]}
                              for s in decoded]}


def logo_vectors() -> tuple[bytes, dict]:
    raw = encode_logo_file([(11, 1024, _logo_png(7)), (12, 1025, bytes(1152)), (21, 1032, _logo_png(1))])
    logos = decode_logo_file(raw)
    return raw, {"file": "logo-sample.dat", "sha256": hashlib.sha256(raw).hexdigest(),
                 "note": "service 1025 has no logo (1152 zero bytes) and is skipped; png is the payload with PLTE+tRNS inserted",
                 "logos": [{"channel_no": lg.channel_no, "service_id": lg.service_id,
                            "png_base64": base64.b64encode(lg.png).decode()} for lg in logos]}


def files() -> dict[Path, bytes]:
    epg_raw, epg_json = epg_vectors()
    logo_raw, logo_json = logo_vectors()
    def js(d: dict) -> bytes:
        return (json.dumps(d, ensure_ascii=False, indent=1) + "\n").encode()
    return {
        OUT / "codes.json": js(codes_vectors()),
        OUT / "series.json": js(series_vectors()),
        OUT / "titles.json": js(titles_vectors()),
        OUT / "xsrs.json": js(xsrs_vectors()),
        OUT / "description.json": js(description_vectors()),
        OUT / "epg-sample.dat": epg_raw, OUT / "epg-sample.json": js(epg_json),
        OUT / "logo-sample.dat": logo_raw, OUT / "logo-sample.json": js(logo_json),
    }


def main(argv: list[str]) -> int:
    wanted = files()
    if "--check" in argv:
        stale = [p.name for p, data in wanted.items() if not p.exists() or p.read_bytes() != data]
        if stale:
            print("stale:", ", ".join(stale), "- run `uv run python -m bdzbridge.tools.portkit`")
            return 1
        print("docs/port is up to date")
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for p, data in wanted.items():
        p.write_bytes(data)
        print("wrote", p)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
