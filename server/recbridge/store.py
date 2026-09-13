"""SQLite cache of the recorder's EPG plus a little metadata. Reads are cheap; refresh replaces per broadcasting type."""
from __future__ import annotations

import sqlite3
import threading
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timedelta

from .recorder import codes
from .recorder.epg import JST, Service

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS channels (
  bt TEXT NOT NULL, service_id INTEGER NOT NULL, name TEXT NOT NULL, sort INTEGER NOT NULL,
  PRIMARY KEY (bt, service_id));
CREATE TABLE IF NOT EXISTS programs (
  bt TEXT NOT NULL, service_id INTEGER NOT NULL, event_id INTEGER NOT NULL,
  start INTEGER NOT NULL, end INTEGER NOT NULL,
  title TEXT, description TEXT, extended TEXT, genre1 INTEGER, genre2 INTEGER, genres TEXT,
  copy_control INTEGER, parental INTEGER, ref_service_id INTEGER, ref_event_id INTEGER,
  search_text TEXT,
  PRIMARY KEY (bt, service_id, event_id, start));
CREATE INDEX IF NOT EXISTS ix_programs_time ON programs (bt, service_id, start);
CREATE INDEX IF NOT EXISTS ix_programs_start ON programs (bt, start);
"""


@dataclass
class ProgramRow:
    bt: str
    service_id: int
    service_name: str
    event_id: int
    start: datetime
    end: datetime
    title: str
    description: str
    extended: str
    genres: list[tuple[int, int]]
    copy_control: int
    parental: int
    is_reference: bool
    ref_service_id: int | None
    ref_event_id: int | None


SCHEMA_VERSION = "2"


def search_norm(text: str) -> str:
    """Case-folded NFKC form, so that ＶＩＶＡＮＴ, VIVANT and vivant all match."""
    return unicodedata.normalize("NFKC", text).casefold()


class Store:
    def __init__(self, path: str):
        self.path = path
        self._lock = threading.Lock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        with self.db:
            self.db.executescript(_SCHEMA)
            if self.get_meta("schema_version") != SCHEMA_VERSION:
                # the cache is disposable: rebuild tables on a schema change
                self.db.executescript("DROP TABLE programs; DROP TABLE channels; DELETE FROM meta WHERE key LIKE 'epg_refreshed:%';")
                self.db.executescript(_SCHEMA)
                self.db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)", (SCHEMA_VERSION,))

    # --- meta ---
    def get_meta(self, key: str) -> str | None:
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row["value"] if row else None

    def set_meta(self, key: str, value: str) -> None:
        with self._lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, value))

    # --- refresh ---
    def replace_services(self, bt: str, services: list[Service]) -> int:
        rows = []
        for svc in services:
            for pr in svc.programs:
                rows.append((bt, svc.service_id, pr.event_id, int(pr.start.timestamp()), int(pr.end.timestamp()),
                             pr.title, pr.description, pr.extended,
                             pr.genres[0][0] if pr.genres else None, pr.genres[0][1] if pr.genres else None,
                             ",".join(f"{a}.{b}" for a, b in pr.genres), pr.copy_control, pr.parental_rating,
                             pr.ref_service_id, pr.ref_event_id,
                             search_norm(f"{pr.title} {pr.description}") if not pr.is_reference else None))
        with self._lock, self.db:
            self.db.execute("DELETE FROM programs WHERE bt=?", (bt,))
            self.db.execute("DELETE FROM channels WHERE bt=?", (bt,))
            self.db.executemany("INSERT INTO channels (bt, service_id, name, sort) VALUES (?,?,?,?)",
                                [(bt, s.service_id, s.name, i) for i, s in enumerate(services)])
            self.db.executemany("INSERT OR REPLACE INTO programs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
            self.db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                            (f"epg_refreshed:{bt}", datetime.now(JST).isoformat(timespec="seconds")))
        return len(rows)

    # --- queries ---
    def channels(self, bt: str | None = None) -> list[dict]:
        q = "SELECT bt, service_id, name, sort FROM channels"
        args: tuple = ()
        if bt:
            q += " WHERE bt=?"
            args = (bt,)
        q += " ORDER BY bt, sort"
        return [dict(r) for r in self.db.execute(q, args)]

    _SELECT = """
    SELECT p.bt, p.service_id, c.name AS service_name, p.event_id, p.start, p.end,
           COALESCE(NULLIF(p.title,''), r.title, '') AS title,
           COALESCE(NULLIF(p.description,''), r.description, '') AS description,
           COALESCE(NULLIF(p.extended,''), r.extended, '') AS extended,
           COALESCE(NULLIF(p.genres,''), r.genres, '') AS genres,
           COALESCE(p.copy_control, r.copy_control, 0) AS copy_control,
           COALESCE(p.parental, r.parental, 0) AS parental,
           p.ref_service_id, p.ref_event_id
    FROM programs p
    LEFT JOIN channels c ON c.bt=p.bt AND c.service_id=p.service_id
    LEFT JOIN programs r ON r.bt=p.bt AND r.service_id=p.ref_service_id AND r.event_id=p.ref_event_id
    """

    @staticmethod
    def _row(r: sqlite3.Row) -> ProgramRow:
        genres = [tuple(int(x) for x in g.split(".")) for g in (r["genres"] or "").split(",") if g]
        return ProgramRow(bt=r["bt"], service_id=r["service_id"], service_name=r["service_name"] or "",
                          event_id=r["event_id"], start=datetime.fromtimestamp(r["start"], JST),
                          end=datetime.fromtimestamp(r["end"], JST), title=r["title"], description=r["description"],
                          extended=r["extended"], genres=genres, copy_control=r["copy_control"], parental=r["parental"],
                          is_reference=r["ref_event_id"] is not None, ref_service_id=r["ref_service_id"],
                          ref_event_id=r["ref_event_id"])

    def programs(self, *, bt: str | None = None, service_id: int | None = None, since: datetime | None = None,
                 until: datetime | None = None, query: str | None = None, include_references: bool = False,
                 limit: int = 500, offset: int = 0) -> list[ProgramRow]:
        where, args = [], []
        if bt:
            where.append("p.bt=?"); args.append(bt)
        if service_id is not None:
            where.append("p.service_id=?"); args.append(service_id)
        if since:
            where.append("p.end>?"); args.append(int(since.timestamp()))
        if until:
            where.append("p.start<?"); args.append(int(until.timestamp()))
        if query:
            where.append("COALESCE(p.search_text, r.search_text, '') LIKE ?")
            args.append(f"%{search_norm(query)}%")
        if not include_references:
            where.append("p.ref_event_id IS NULL")
        sql = self._SELECT + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY p.start, p.bt, p.service_id LIMIT ? OFFSET ?"
        args += [limit, offset]
        return [self._row(r) for r in self.db.execute(sql, args)]

    def program(self, bt: str, service_id: int, event_id: int) -> ProgramRow | None:
        r = self.db.execute(self._SELECT + " WHERE p.bt=? AND p.service_id=? AND p.event_id=? ORDER BY p.start LIMIT 1",
                            (bt, service_id, event_id)).fetchone()
        return self._row(r) if r else None

    def now_on_air(self, bt: str, at: datetime | None = None) -> list[ProgramRow]:
        at = at or datetime.now(JST)
        rows = self.db.execute(self._SELECT + " WHERE p.bt=? AND p.start<=? AND p.end>? ORDER BY c.sort",
                               (bt, int(at.timestamp()), int(at.timestamp()))).fetchall()
        return [self._row(r) for r in rows]

    def day_range(self, day: datetime) -> tuple[datetime, datetime]:
        """A TV day runs 04:00 to 04:00 JST (the convention Japanese guides use)."""
        start = day.astimezone(JST).replace(hour=4, minute=0, second=0, microsecond=0)
        return start, start + timedelta(days=1)

    def summary(self) -> dict:
        out = {}
        for bt in codes.EPG_FILES:
            n = self.db.execute("SELECT COUNT(*) FROM programs WHERE bt=? AND ref_event_id IS NULL", (bt,)).fetchone()[0]
            c = self.db.execute("SELECT COUNT(*) FROM channels WHERE bt=?", (bt,)).fetchone()[0]
            out[bt] = {"channels": c, "programs": n, "refreshed": self.get_meta(f"epg_refreshed:{bt}")}
        return out
