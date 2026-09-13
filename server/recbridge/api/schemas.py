from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

Broadcasting = Literal["td", "bs", "cs", "bs4k", "cs4k"]
Quality = Literal["DR", "XR", "XSR", "SR", "LSR", "LR", "ER", "EER"]
Repeat = Literal["none", "title", "daily", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "mon-fri", "mon-sat"]


class Channel(BaseModel):
    broadcasting: Broadcasting
    service_id: int
    name: str
    sort: int
    logo: str | None = Field(default=None, description="station logo as a data: URL (64x36 PNG from the recorder)")


class Genre(BaseModel):
    level1: int
    level2: int
    label: str


class Program(BaseModel):
    broadcasting: Broadcasting
    service_id: int
    service_name: str
    event_id: int
    start: datetime
    end: datetime
    duration_sec: int
    title: str
    description: str
    extended: str = ""
    genres: list[Genre]
    copy_control: int
    parental_rating: int
    is_reference: bool = False
    ref_service_id: int | None = None
    ref_event_id: int | None = None


class Reservation(BaseModel):
    id: str
    title: str
    start: datetime
    end: datetime
    duration_sec: int
    broadcasting: str
    service_id: int
    service_name: str | None = None
    event_id: int | None
    tracks_program: bool
    repeat: str
    repeat_label: str
    quality: str
    quality_label: str
    recording: bool
    conflict: bool
    destination: str
    size_mb: int | None
    created_by_app: bool
    genres: list[Genre] = Field(default_factory=list, description="from the EPG cache when the reservation tracks a program that is still in it")


class ReservationCreate(BaseModel):
    broadcasting: Broadcasting
    service_id: int
    event_id: int | None = Field(default=None, description="ARIB event_id; when given, start/duration/title come from the EPG unless overridden")
    start: datetime | None = None
    duration_sec: int | None = Field(default=None, ge=60, le=24 * 3600)
    title: str | None = Field(default=None, description="used for time-based reservations; with event_id the recorder replaces it with the EPG title")
    quality: Quality | None = None
    repeat: Repeat | None = None
    force: bool = Field(default=False, description="create even if the conflict check reports overlapping reservations")


class ReservationUpdate(BaseModel):
    quality: Quality | None = None
    repeat: Repeat | None = None
    title: str | None = Field(default=None, description="time-based reservations only")
    start: datetime | None = Field(default=None, description="time-based reservations only")
    duration_sec: int | None = Field(default=None, ge=60, le=24 * 3600, description="time-based reservations only")


class ConflictReport(BaseModel):
    conflicts: list[Reservation]
    ok: bool


class ReservationCreated(BaseModel):
    reservation: Reservation
    conflicts: list[Reservation]


class RecordedTitle(BaseModel):
    id: str
    title: str
    start: datetime
    duration_sec: int
    broadcasting: str
    service_id: int
    service_name: str | None = None
    quality: str
    protected: bool
    is_new: bool
    destination: str
    size_mb: int | None
    dlna_id: str = Field(description="the title's DLNA object id on the recorder")
    genres: list[Genre] = Field(default_factory=list, description="from the recorder's genreID")


class PlaybackStatus(BaseModel):
    power: str | None = None
    play: str | None = None
    title_id: str | None = None
    position_sec: int | None = None
    chapter: int | None = None


class PlaybackControl(BaseModel):
    operation: Literal["stop", "pause", "resume"] = Field(description="resume is only valid while paused")


class TitleDetail(BaseModel):
    id: str
    summary: str = ""
    details: list[str] = []


class RecorderStatus(BaseModel):
    configured: bool
    host: str | None = None
    friendly_name: str | None = None
    model: str | None = None
    product: str | None = None
    epg_capable: bool | None = None
    udn: str | None = None
    firmware: str | None = None
    power: str | None = None
    play: str | None = None
    epg: dict


class RecorderCandidate(BaseModel):
    host: str
    port: int
    friendly_name: str
    product: str
    model: str
    udn: str
    epg_capable: bool
    location: str
    via: str
    selected: bool = False


class RecorderSelect(BaseModel):
    host: str


class Defaults(BaseModel):
    quality: Quality
    repeat: Repeat
    qualities: dict[str, str]
    repeats: dict[str, str]
    broadcastings: dict[str, str]
    genres: dict[int, str] = Field(default_factory=dict, description="ARIB level-1 genre code → label")
