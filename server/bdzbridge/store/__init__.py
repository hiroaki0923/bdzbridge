"""SQLite cache of the recorder's EPG plus the app's own data (rules, channel preferences, title summaries, meta).

Reads are cheap; a refresh replaces the guide per broadcasting type. `Store` is assembled from one mixin per area."""
from __future__ import annotations

from .base import SCHEMA_VERSION, ProgramRow, StoreBase, search_norm
from .guide import GuideMixin
from .rules import RulesMixin
from .titles import TitlesMixin

__all__ = ["SCHEMA_VERSION", "ProgramRow", "Store", "search_norm"]


class Store(GuideMixin, RulesMixin, TitlesMixin, StoreBase):
    pass
