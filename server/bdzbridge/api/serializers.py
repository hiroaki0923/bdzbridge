"""Recorder / store objects → API models."""
from __future__ import annotations

import base64
from datetime import datetime, timedelta

from ..recorder import codes
from ..recorder.client import RecorderClient
from ..recorder.epg import JST
from ..recorder.series import series_key
from ..recorder.xsrs import RecordedTitle as XTitle
from ..recorder.xsrs import RecorderRule as XRecorderRule
from ..recorder.xsrs import Reservation as XReservation
from ..store import ProgramRow, Store
from . import schemas as S


def _genres(pairs) -> list[S.Genre]:
    return [S.Genre(level1=a, level2=b, label=codes.GENRE_LABEL.get(a, "不明"), label2=codes.sub_genre(a, b))
            for a, b in pairs]


def _genres_from_code(code: int | None) -> list[S.Genre]:
    """The recorder's genreID is the first ARIB content descriptor pair packed as level1 * 16 + level2."""
    return _genres([(code >> 4, code & 0xF)]) if code is not None else []


def program_out(p: ProgramRow, compact: bool = False) -> S.Program:
    return S.Program(broadcasting=p.bt, service_id=p.service_id, service_name=p.service_name, event_id=p.event_id,
                     start=p.start, end=p.end, duration_sec=int((p.end - p.start).total_seconds()), title=p.title,
                     description="" if compact else p.description, extended="" if compact else p.extended,
                     genres=_genres(p.genres),
                     copy_control=p.copy_control, parental_rating=p.parental, is_reference=p.is_reference,
                     ref_service_id=p.ref_service_id, ref_event_id=p.ref_event_id)


def reservation_out(r: XReservation, store: Store | None = None) -> S.Reservation:
    bt = codes.BROADCASTING_BY_CODE.get(r.broadcasting_type, str(r.broadcasting_type))
    repeat = codes.REPEAT_BY_CODE.get(r.repeat_code, r.repeat_code)
    quality = codes.QUALITY_BY_CODE.get(r.quality_code, str(r.quality_code))
    name, genres = None, []
    if store and bt in codes.EPG_FILES:
        ch = [c for c in store.channels(bt) if c["service_id"] == r.service_id]
        name = ch[0]["name"] if ch else None
        if r.event_id is not None and (p := store.program(bt, r.service_id, r.event_id)):
            genres = _genres(p.genres)
    if not genres:
        genres = _genres_from_code(r.genre_code)
    return S.Reservation(id=r.id, title=r.title, start=r.start, end=r.start + timedelta(seconds=r.duration_sec),
                         duration_sec=r.duration_sec, broadcasting=bt, service_id=r.service_id, service_name=name,
                         event_id=r.event_id, tracks_program=r.event_id is not None, repeat=repeat,
                         repeat_label=codes.REPEAT_LABEL.get(repeat, repeat), quality=quality,
                         quality_label=codes.QUALITY_LABEL.get(quality, quality), recording=r.recording,
                         conflict=r.conflict, destination=r.destination, size_mb=r.size_mb,
                         created_by_app=r.creator == "2200", created_by_recorder=r.creator == "1100",
                         genres=genres)


def title_out(t: XTitle, store: Store | None = None) -> S.RecordedTitle:
    bt = codes.BROADCASTING_BY_CODE.get(t.broadcasting_type, str(t.broadcasting_type))
    name = None
    if store and bt in codes.EPG_FILES:
        ch = [c for c in store.channels(bt) if c["service_id"] == t.service_id]
        name = ch[0]["name"] if ch else None
    return S.RecordedTitle(id=t.id, title=t.title, start=t.start, duration_sec=t.duration_sec, broadcasting=bt,
                           service_id=t.service_id, service_name=name,
                           quality=codes.QUALITY_BY_CODE.get(t.quality_code, str(t.quality_code)), protected=t.protected,
                           is_new=t.is_new, destination=t.destination, size_mb=t.size_mb,
                           dlna_id=RecorderClient.cds_id(t.id, t.destination), genres=_genres_from_code(t.genre_code),
                           series=series_key(t.title), last_played=t.last_played, resume_sec=t.resume_sec,
                           watch_state="unwatched" if t.is_new else ("partway" if (t.resume_sec or 0) > 0 else "watched"))


def _data_url(png: bytes | None) -> str | None:
    return "data:image/png;base64," + base64.b64encode(png).decode() if png else None


def channel_out(c: dict) -> S.Channel:
    return S.Channel(broadcasting=c["bt"], service_id=c["service_id"], name=c["name"], sort=c["sort"],
                     logo=_data_url(c["logo"]), hidden=bool(c["hidden"]))


def rule_out(b, r: dict) -> S.Rule:
    name = None
    if r["bt"] and r["service_id"] is not None:
        ch = [c for c in b.store.channels(r["bt"]) if c["service_id"] == r["service_id"]]
        name = ch[0]["name"] if ch else None
    return S.Rule(id=r["id"], query=r["query"], broadcasting=r["bt"], service_id=r["service_id"], service_name=name,
                  title_only=bool(r["title_only"]), quality=r["quality"], enabled=bool(r["enabled"]), created=r["created"])

def recorder_rule_out(r: XRecorderRule) -> S.RecorderRule:
    def quality(code: int | None) -> str | None:
        return None if code is None else codes.QUALITY_BY_CODE.get(code, str(code))
    genres = _genres([(r.genre_level1, r.genre_level2)]) if r.genre_level1 is not None else []
    return S.RecorderRule(id=r.id, name=r.name, keywords=r.keywords, excluded=r.excluded, logic=r.logic,
                          logic_label=codes.RULE_LOGIC_LABEL.get(r.logic, r.logic), genres=genres,
                          time_scope=r.time_scope, time_scope_label=codes.TIME_SCOPE_LABEL.get(r.time_scope, r.time_scope),
                          broadcasting_scope=r.broadcasting_scope,
                          broadcasting_scope_label=codes.BROADCASTING_SCOPE_LABEL.get(r.broadcasting_scope, r.broadcasting_scope),
                          quality=quality(r.quality_code), quality_4k=quality(r.quality_code_4k), destination=r.destination)


def log_out(r: dict) -> S.AutoLogEntry:
    return S.AutoLogEntry(id=r["id"], rule_id=r["rule_id"], rule_query=r["rule_query"], broadcasting=r["bt"],
                          service_id=r["service_id"], event_id=r["event_id"], title=r["title"],
                          start=datetime.fromtimestamp(r["start"], JST), status=r["status"], message=r["message"], at=r["at"])
