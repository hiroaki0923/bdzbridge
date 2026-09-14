"""SQLite cache of the recorder's EPG plus a little metadata. Reads are cheap; refresh replaces per broadcasting type."""
from __future__ import annotations

import sqlite3
import threading
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timedelta

from .recorder import codes
from .recorder.epg import JST, Service
from .recorder.logo import Logo

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
CREATE TABLE IF NOT EXISTS logos (
  bt TEXT NOT NULL, service_id INTEGER NOT NULL, channel_no INTEGER NOT NULL, png BLOB NOT NULL,
  PRIMARY KEY (bt, service_id));
CREATE TABLE IF NOT EXISTS rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT, query TEXT NOT NULL, bt TEXT, service_id INTEGER,
  title_only INTEGER NOT NULL DEFAULT 1, quality TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS auto_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT, rule_id INTEGER NOT NULL, bt TEXT NOT NULL, service_id INTEGER NOT NULL,
  event_id INTEGER NOT NULL, title TEXT NOT NULL, start INTEGER NOT NULL, status TEXT NOT NULL, message TEXT,
  at TEXT NOT NULL, UNIQUE (rule_id, bt, service_id, event_id));
CREATE TABLE IF NOT EXISTS channel_prefs (
  bt TEXT NOT NULL, service_id INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0, position INTEGER,
  PRIMARY KEY (bt, service_id));
CREATE TABLE IF NOT EXISTS title_summaries (id TEXT PRIMARY KEY, summary TEXT NOT NULL, at TEXT NOT NULL);
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


SCHEMA_VERSION = "3"


def search_norm(text: str) -> str:
    """Case-folded NFKC form, so that ＳＡＭＰＬＥ, SAMPLE and sample all match."""
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
                self.db.executescript("DROP TABLE programs; DROP TABLE channels; DROP TABLE IF EXISTS logos; DELETE FROM meta WHERE key LIKE 'epg_refreshed:%';")
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

    # --- recorded-title summaries (for duplicate detection; the recorder is slow to ask) ---
    def title_summary(self, title_id: str) -> str | None:
        r = self.db.execute("SELECT summary FROM title_summaries WHERE id=?", (title_id,)).fetchone()
        return r[0] if r else None

    def set_title_summary(self, title_id: str, summary: str) -> None:
        with self._lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO title_summaries (id, summary, at) VALUES (?,?,?)",
                            (title_id, summary, datetime.now(JST).isoformat(timespec="seconds")))

    # --- auto-reservation rules ---
    def rules(self) -> list[dict]:
        return [dict(r) for r in self.db.execute("SELECT * FROM rules ORDER BY id")]

    def rule(self, rule_id: int) -> dict | None:
        r = self.db.execute("SELECT * FROM rules WHERE id=?", (rule_id,)).fetchone()
        return dict(r) if r else None

    def add_rule(self, query: str, bt: str | None, service_id: int | None, title_only: bool, quality: str) -> dict:
        with self._lock, self.db:
            cur = self.db.execute("INSERT INTO rules (query, bt, service_id, title_only, quality, enabled, created) VALUES (?,?,?,?,?,1,?)",
                                  (query.strip(), bt, service_id, int(title_only), quality,
                                   datetime.now(JST).isoformat(timespec="seconds")))
        return self.rule(cur.lastrowid)  # type: ignore[return-value]

    def update_rule(self, rule_id: int, **fields) -> dict | None:
        cols = {k: (int(v) if isinstance(v, bool) else v) for k, v in fields.items()
                if v is not None and k in ("enabled", "quality", "title_only", "query")}
        if cols:
            with self._lock, self.db:
                self.db.execute(f"UPDATE rules SET {', '.join(f'{k}=?' for k in cols)} WHERE id=?", (*cols.values(), rule_id))
        return self.rule(rule_id)

    def delete_rule(self, rule_id: int) -> bool:
        with self._lock, self.db:
            n = self.db.execute("DELETE FROM rules WHERE id=?", (rule_id,)).rowcount
            self.db.execute("DELETE FROM auto_log WHERE rule_id=?", (rule_id,))
        return n > 0

    def rule_matches(self, rule: dict, since: datetime, limit: int = 300) -> list[ProgramRow]:
        """Programs starting at or after `since` that the rule matches (title only, or title + description)."""
        rows = self.programs(bt=rule["bt"], service_id=rule["service_id"], since=since, query=rule["query"], limit=limit)
        if rule["title_only"]:
            q = search_norm(rule["query"])
            rows = [p for p in rows if q in search_norm(p.title)]
        return [p for p in rows if p.start >= since]

    def auto_logged(self, rule_id: int, bt: str, service_id: int, event_id: int) -> bool:
        return self.db.execute("SELECT 1 FROM auto_log WHERE rule_id=? AND bt=? AND service_id=? AND event_id=?",
                               (rule_id, bt, service_id, event_id)).fetchone() is not None

    def auto_log_add(self, rule_id: int, p: ProgramRow, status: str, message: str = "") -> None:
        with self._lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO auto_log (rule_id, bt, service_id, event_id, title, start, status, message, at)"
                            " VALUES (?,?,?,?,?,?,?,?,?)",
                            (rule_id, p.bt, p.service_id, p.event_id, p.title, int(p.start.timestamp()), status, message or None,
                             datetime.now(JST).isoformat(timespec="seconds")))

    def auto_log(self, limit: int = 50) -> list[dict]:
        return [dict(r) for r in self.db.execute(
            "SELECT l.*, r.query AS rule_query FROM auto_log l LEFT JOIN rules r ON r.id=l.rule_id ORDER BY l.id DESC LIMIT ?", (limit,))]

    def replace_logos(self, bt: str, logos: list[Logo]) -> None:
        with self._lock, self.db:
            self.db.execute("DELETE FROM logos WHERE bt=?", (bt,))
            self.db.executemany("INSERT OR REPLACE INTO logos (bt, service_id, channel_no, png) VALUES (?,?,?,?)",
                                [(bt, lg.service_id, lg.channel_no, lg.png) for lg in logos])

    # --- queries ---
    def channels(self, bt: str | None = None, include_hidden: bool = False) -> list[dict]:
        """Channels in the user's order (else the recorder's); `logo` is the station's PNG (bytes) or None."""
        q = ("SELECT c.bt, c.service_id, c.name, c.sort, l.png AS logo, COALESCE(cp.hidden, 0) AS hidden, cp.position"
             " FROM channels c LEFT JOIN logos l ON l.bt=c.bt AND l.service_id=c.service_id"
             " LEFT JOIN channel_prefs cp ON cp.bt=c.bt AND cp.service_id=c.service_id")
        where, args = [], []
        if bt:
            where.append("c.bt=?"); args.append(bt)
        if not include_hidden:
            where.append("COALESCE(cp.hidden, 0)=0")
        if where:
            q += " WHERE " + " AND ".join(where)
        q += " ORDER BY c.bt, COALESCE(cp.position, 100000 + c.sort), c.sort"
        return [dict(r) for r in self.db.execute(q, args)]

    def set_channel_prefs(self, bt: str, order: list[int] | None = None, hidden: list[int] | None = None) -> None:
        """`order`: service ids in the wanted order (empty list = back to the recorder's order);
        `hidden`: the service ids to hide (empty list = show everything). None leaves that aspect alone."""
        with self._lock, self.db:
            ids = [r["service_id"] for r in self.db.execute("SELECT service_id FROM channels WHERE bt=?", (bt,))]
            for sid in ids:
                self.db.execute("INSERT OR IGNORE INTO channel_prefs (bt, service_id) VALUES (?, ?)", (bt, sid))
            if order is not None:
                pos = {sid: i for i, sid in enumerate(order)}
                for sid in ids:
                    self.db.execute("UPDATE channel_prefs SET position=? WHERE bt=? AND service_id=?", (pos.get(sid), bt, sid))
            if hidden is not None:
                for sid in ids:
                    self.db.execute("UPDATE channel_prefs SET hidden=? WHERE bt=? AND service_id=?", (int(sid in hidden), bt, sid))

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
    LEFT JOIN channel_prefs cp ON cp.bt=p.bt AND cp.service_id=p.service_id
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
                 include_hidden: bool = False,
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
        if not include_hidden:
            where.append("COALESCE(cp.hidden, 0)=0")
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
