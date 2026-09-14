"""Keyword auto-reservation rules and what they did (auto_log)."""
from __future__ import annotations

from datetime import datetime

from ..recorder.epg import JST
from .base import ProgramRow, search_norm


class RulesMixin:
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

