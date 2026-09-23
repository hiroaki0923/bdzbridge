from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator, model_validator

Broadcasting = Literal["td", "bs", "cs", "bs4k", "cs4k"]
Quality = Literal["DR", "XR", "XSR", "SR", "LSR", "LR", "ER", "EER"]
Repeat = Literal["none", "title", "daily", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "mon-fri", "mon-sat"]


class Channel(BaseModel):
    broadcasting: Broadcasting
    service_id: int
    name: str
    sort: int
    logo: str | None = Field(default=None, description="station logo as a data: URL (64x36 PNG from the recorder)")
    hidden: bool = False


class ChannelPrefs(BaseModel):
    order: list[int] | None = Field(default=None, description="service ids in the wanted order; [] restores the recorder's order")
    hidden: list[int] | None = Field(default=None, description="service ids to hide from the guide and search; [] shows all")


class Genre(BaseModel):
    level1: int
    level2: int | None = Field(description="None stands for the whole level-1 genre, as a recorder condition can")
    label: str
    label2: str | None = Field(None, description="the sub-genre's name; absent for a whole genre or an unused code")


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
    created_by_recorder: bool = Field(False, description="レコーダー自身が入れた予約（おまかせ録画）。消してもレコーダーが入れ直す")
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
    recording: bool = Field(default=False, description="the recorder is still writing to this one; it refuses to delete it")
    destination: str
    size_mb: int | None
    dlna_id: str = Field(description="the title's DLNA object id on the recorder")
    genres: list[Genre] = Field(default_factory=list, description="from the recorder's genreID")
    series: str = Field(default="", description="grouping key derived from the title (episodes of one programme share it)")
    last_played: datetime | None = None
    resume_sec: int | None = Field(default=None, description="where playback stopped last time, 0 when it ran to the end")
    watch_state: Literal["unwatched", "partway", "watched"] = "unwatched"


class TitleGroup(BaseModel):
    key: str
    name: str
    count: int
    size_mb: int
    latest: datetime
    earliest: datetime
    protected_count: int
    new_count: int


class TitlesDelete(BaseModel):
    ids: list[str] = Field(min_length=1, max_length=300)


class TitleSkipped(BaseModel):
    id: str
    reason: str


class TitlesDeleteResult(BaseModel):
    deleted: list[str]
    skipped: list[TitleSkipped]


class DuplicateSet(BaseModel):
    title: str
    confidence: Literal["high", "low"] = Field(description="high: same title, length and programme text; low: same title and length only")
    size_mb: int
    items: list[RecordedTitle]
    keep: str = Field(description="id of the copy worth keeping")
    suggest_delete: list[str]
    reasons: dict[str, str] = Field(default_factory=dict, description="per id, why it is kept or suggested for deletion")


class Job(BaseModel):
    """A background job. Poll GET /jobs/{id}; POST /jobs/{id}/cancel stops it after the current item."""
    id: str
    kind: Literal["delete", "protect", "duplicates"]
    total: int
    done: int
    finished: bool
    cancelled: bool
    error: str | None = None
    result: dict[str, Any] = Field(default_factory=dict, description="delete: deleted/skipped; protect: changed/skipped; duplicates: sets")


class TitlesProtect(BaseModel):
    ids: list[str] = Field(min_length=1, max_length=500)
    protected: bool


class PlaybackStatus(BaseModel):
    power: str | None = None
    play: str | None = None
    title_id: str | None = None
    position_sec: int | None = None
    chapter: int | None = None


class PlaybackControl(BaseModel):
    operation: Literal["stop", "pause", "resume"] = Field(description="resume is only valid while paused")


class TitleUpdate(BaseModel):
    protected: bool | None = Field(default=None, description="protect from deletion (the recorder's 保護)")
    is_new: bool | None = None
    title: str | None = Field(default=None, min_length=1, max_length=200)


class TitleFlags(BaseModel):
    id: str
    protected: bool | None = None
    is_new: bool | None = None
    title: str | None = None


class TitleDetail(BaseModel):
    id: str
    summary: str = ""
    details: list[str] = []


class Storage(BaseModel):
    destination: str = "HDD"
    total_bytes: int
    free_bytes: int


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
    storage: Storage | None = None
    reachable: bool | None = Field(default=None, description="False when the recorder is not answering on the network (try POST /recorder/wake)")
    mac: str | None = None
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


class RuleCreate(BaseModel):
    query: str = Field(min_length=1, max_length=100, description="matched case-insensitively (NFKC) against the title, or title + description")
    broadcasting: Broadcasting | None = None
    service_id: int | None = None
    title_only: bool = True
    quality: Quality | None = None


class RuleUpdate(BaseModel):
    enabled: bool | None = None
    quality: Quality | None = None
    title_only: bool | None = None


RuleLogic = Literal["OR", "AND"]


class RecorderRuleCreate(BaseModel):
    """A condition for the recorder's own おまかせ・まる録, which then records by it without this server. The
    channel narrowing the recorder's screen offers cannot be set over the LAN."""
    keywords: list[str] = Field(default_factory=list, max_length=5, description="as the recorder's own screen allows: up to 5; a genre alone is also a condition")
    excluded: list[str] = Field(default_factory=list, max_length=2, description="up to 2")
    logic: RuleLogic = "OR"
    genre_level1: int | None = Field(None, ge=0, le=0xF, description="ARIB level-1 genre; alone it means the whole genre")
    genre_level2: int | None = Field(None, ge=0, le=0xF, description="the sub-genre within level1")
    time_scope: str = Field("ALL", max_length=16, description="ALL, MORNING, AFTERNOON, NIGHT, MIDNIGHT")
    broadcasting_scope: str = Field("ALL", max_length=16, description="ALL, TRD, BSD, CSD, ADVBSD, ADVCSD; an unknown value widens to ALL on the recorder")
    quality: Quality | None = Field(None, description="the server's default when omitted; with ALL it is sent for BS4K/CS4K as well, "
                                                      "which the recorder would otherwise record in DR")

    @field_validator("keywords", "excluded")
    @classmethod
    def _words(cls, words: list[str]) -> list[str]:
        cleaned = [w.strip() for w in words if w.strip()]
        if any(len(w) > 50 for w in cleaned):
            raise ValueError("a keyword is at most 50 characters")
        return cleaned

    @model_validator(mode="after")
    def _something_to_match(self) -> RecorderRuleCreate:
        if not self.keywords and self.genre_level1 is None:
            raise ValueError("a keyword or a genre is needed")
        if self.genre_level2 is not None and self.genre_level1 is None:
            raise ValueError("a sub-genre needs its level-1 genre")
        return self


class RecorderRule(BaseModel):
    id: str
    name: str = Field(description="composed by the recorder from the genre and the keywords")
    keywords: list[str]
    excluded: list[str]
    logic: str
    logic_label: str
    genres: list[Genre]
    time_scope: str
    time_scope_label: str
    broadcasting_scope: str
    broadcasting_scope_label: str
    quality: str | None = Field(description="録画モード(地上/BS/CS)")
    quality_4k: str | None = Field(description="録画モード(BS4K/CS4K); DR when the condition was made without one")
    destination: str


class Rule(BaseModel):
    id: int
    query: str
    broadcasting: Broadcasting | None = None
    service_id: int | None = None
    service_name: str | None = None
    title_only: bool
    quality: Quality
    enabled: bool
    created: datetime


class AutoLogEntry(BaseModel):
    id: int
    rule_id: int
    rule_query: str | None = None
    broadcasting: str
    service_id: int
    event_id: int
    title: str
    start: datetime
    status: Literal["reserved", "conflict", "error"]
    message: str | None = None
    at: datetime


class AutoRunResult(BaseModel):
    rules: int
    checked: int
    reserved: int
    conflicts: int
    errors: int
    notified: list[str] = Field(default_factory=list, description="channels that delivered the report: email, webhook")
    at: datetime | None = None


class MonitorResult(BaseModel):
    free_gb: float | None = None
    low_space: bool
    new_conflicts: list[str]
    notified: list[str]


class WakeResult(BaseModel):
    awake: bool = Field(description="the reservation service answers after the magic packets")
    mac: str | None


class PowerResult(BaseModel):
    power: str = Field(description="the recorder's reply to X_PowerControl, normally PowerOn")


class NotifyStatus(BaseModel):
    configured: bool
    email: bool
    webhook: bool
    to: str | None = None
    free_gb: float | None = Field(default=None, description="low-space warning threshold, 0 = off")
    sent: list[str] = Field(default_factory=list)


class Defaults(BaseModel):
    quality: Quality
    repeat: Repeat
    qualities: dict[str, str]
    repeats: dict[str, str]
    broadcastings: dict[str, str]
    genres: dict[int, str] = Field(default_factory=dict, description="ARIB level-1 genre code → label")
    sub_genres: dict[int, dict[int, str]] = Field(default_factory=dict,
                                                  description="ARIB level-1 genre code → sub-genre code → label")
