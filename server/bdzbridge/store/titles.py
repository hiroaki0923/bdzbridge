"""Cached programme summaries of recorded titles (for duplicate detection; the recorder is slow to ask)."""
from __future__ import annotations

from datetime import datetime

from ..recorder.epg import JST


class TitlesMixin:
    # --- recorded-title summaries (for duplicate detection; the recorder is slow to ask) ---
    def title_summary(self, title_id: str) -> str | None:
        r = self.db.execute("SELECT summary FROM title_summaries WHERE id=?", (title_id,)).fetchone()
        return r[0] if r else None

    def set_title_summary(self, title_id: str, summary: str) -> None:
        with self._lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO title_summaries (id, summary, at) VALUES (?,?,?)",
                            (title_id, summary, datetime.now(JST).isoformat(timespec="seconds")))

