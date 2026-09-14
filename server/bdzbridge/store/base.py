"""Connection, schema, and the meta table. The cache tables are rebuilt on SCHEMA_VERSION changes; user data (rules,
channel preferences, title summaries) is kept."""
from __future__ import annotations

import sqlite3
import threading
import unicodedata
from dataclasses import dataclass
from datetime import datetime

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


class StoreBase:
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

