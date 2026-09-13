from __future__ import annotations

from datetime import datetime, timedelta

import pytest

from recbridge.recorder.epg import JST, Program, Service


def make_services() -> list[Service]:
    day = datetime(2026, 9, 14, 5, 0, tzinfo=JST)
    nhk = Service(1024, "ＮＨＫ総合１・東京", [
        Program(1024, 14792, day, day + timedelta(hours=1), "サンプルニュース　あさの放送", "朝のニュース", "詳細テキスト",
                genres=[(0, 0), (0, 1)], copy_control=2, parental_rating=0),
        Program(1024, 14793, day + timedelta(hours=1), day + timedelta(hours=1, minutes=15), "あさのサンプル", "生活情報", "",
                genres=[(2, 4)]),
        Program(1024, 14800, day + timedelta(days=1, hours=15), day + timedelta(days=1, hours=16), "翌日の番組", "", "x"),
        Program(1024, 14794, day + timedelta(hours=16), day + timedelta(hours=17), "日曜劇場「サンプルドラマ」", "", ""),
    ])
    sub = Service(1025, "ＮＨＫ総合２・東京", [
        Program(1025, 14792, day, day + timedelta(hours=1), ref_service_id=1024, ref_event_id=14792),
    ])
    return [nhk, sub]


@pytest.fixture
def services():
    return make_services()
