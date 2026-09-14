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
    _soap_body,
    build_create_elements,
    build_title_update_elements,
    build_update_elements,
    parse_reservation,
    parse_title,
)
from ..services.titles import group_titles

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "docs" / "port"
FIXTURES = ROOT / "server" / "tests" / "fixtures"

# Titles seen on a real recorder (and a few synthetic ones) that exercise every rule of the grouping heuristic.
SERIES_TITLES = [
    "日曜劇場「ＶＩＶＡＮＴ」第１８話　前半戦完結　乃木＆ノコル", "豊臣兄弟！（３５）秀長誕生",
    "名探偵プリキュア！　＃３３ 名探偵の道も一歩から", "マルコ・ポーロの冒険（２３）「王の中の王フビライ」",
    "[字]おかあさんといっしょ　月曜日", "ドキュメント７２時間ＰＲ", "必殺仕事人Ⅳ　第１４話「主水節分の豆を食べる」",
    "パウ・パトロール「ピカピカパーティーでプカプカピンチ！」", "アニメ　おさるのジョージ「こんがら交換」「みどり、あお」",
    "【土曜ドラマ】憶えのない殺人　後編「迷宮」", "ドラえもん　【夢ホール】【ねこっかぶり】",
    "クレヨンしんちゃん　【ホットケーキはホッとするゾ】", "ピタゴラスイッチ▽フレーミーとたね　▽たこたこピー",
    "ピタゴラスイッチ「この装置　こんな名前がついてましたＳＰ」", "それいけ！アンパンマン「カップケーキちゃんとふでじいさん・他」",
    "刑事コロンボ（４８）「幻の娼（しょう）婦」", "ＢａｂｙＢｕｓーベビーバスー　★大人気の知育アニメがテレビで登場！",
    "タモリ・山中伸弥の！？ＰＲ　人類史３．０　人間とは何か", "土曜ドラマ「ムショラン三ツ星」２分ＰＲ　今後の見どころ紹介！",
    "【土曜ドラマ】天城越え　後編", "フロンティアで会いましょう！（２５）自律神経　最新研究",
    "新プロジェクトＸ「世紀の難工事　関西国際空港」", "ＮＨＫ高校講座　数学Ⅰ　２次不等式[字]", "ミャクぷしゅ",
    "＃１２　いきなり話数で始まる", "日曜劇場「VIVANT」 第1話", "ＮＨＫニュース　おはよう日本[字]", "NHKニュース　おはよう日本",
    "ドラマＡ　第３話[再]", "ドラマA 第3話", "ドラマＡ　第４話", "大河ドラマ「べらぼう」（３６）",
    "映画「男はつらいよ」", "連続テレビ小説　風、薫る（１２１）第２５週「風」", "３分クッキング", "",
]
SUMMARIES = ["（再放送）あらすじ　本文", "あらすじ本文[再]", "", "ドラマ[字]の　あらすじ。"]


def _sample_services() -> list[Service]:
    day = datetime(2026, 9, 14, 5, 0, tzinfo=JST)
    nhk = Service(1024, "ＮＨＫ総合１・東京", [
        Program(1024, 14792, day, day + timedelta(hours=1), "ＮＨＫニュース　おはよう日本[字]", "朝のニュース", "詳細テキスト",
                genres=[(0, 0), (0, 1)], copy_control=2, parental_rating=0),
        Program(1024, 14793, day + timedelta(hours=1), day + timedelta(hours=1, minutes=15), "あさイチ", "生活情報", "",
                genres=[(2, 4)]),
        Program(1024, 14800, day + timedelta(days=1, hours=15), day + timedelta(days=1, hours=16), "翌日の番組", "", "x",
                genres=[(3, 0)], copy_control=1, parental_rating=2),
        Program(1024, 14794, day + timedelta(hours=16), day + timedelta(hours=17), "日曜劇場「ＶＩＶＡＮＴ」", "", ""),
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
        title("0x6", "アニメ　おさるのジョージ「こんがら交換」", timedelta(days=5), genre_code=0x71, size_mb=500),
        title("0x7", "映画「男はつらいよ」", timedelta(days=6), is_new=False, resume_sec=0, genre_code=0x60,
              size_mb=4000),
    ]


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
    }


def codes_vectors() -> dict:
    return {
        "broadcasting": codes.BROADCASTING, "broadcasting_label": codes.BROADCASTING_LABEL,
        "epg_files": codes.EPG_FILES, "logo_files": codes.LOGO_FILES,
        "quality": codes.QUALITY, "quality_label": codes.QUALITY_LABEL,
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

    return {
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
