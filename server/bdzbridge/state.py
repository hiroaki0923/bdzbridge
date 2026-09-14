"""Application state shared by the API and the services: settings, the selected recorder (None until configured),
the store, the notifier, the job registry, and a few caches. Behaviour lives in `services/`."""
from __future__ import annotations

import asyncio
from datetime import datetime

import httpx
from fastapi import HTTPException

from .config import Settings
from .jobs import Jobs
from .recorder.client import RecorderClient
from .recorder.epg import JST
from .recorder.xsrs import RecordedTitle as XTitle
from .services.notify import Notifier
from .store import Store


class Bridge:
    def __init__(self, settings: Settings, recorder: RecorderClient | None, store: Store):
        self.settings, self.recorder, self.store = settings, recorder, store
        self.refresh_lock = asyncio.Lock()
        self.last_error: str | None = None
        self.http = httpx.AsyncClient(timeout=10.0)
        self.notifier = Notifier(settings, self.http)
        self.clock = lambda: datetime.now(JST)  # tests override this
        self.last_autorec: dict | None = None
        self.titles_cache: tuple[float, list[XTitle]] | None = None  # (monotonic time, every recorded title)
        self.jobs = Jobs()

    @property
    def configured(self) -> bool:
        return self.recorder is not None

    def require_recorder(self) -> RecorderClient:
        if self.recorder is None:
            raise HTTPException(503, "recorder not configured: call GET /api/v1/recorders/discover, then PUT /api/v1/recorder")
        return self.recorder

    async def close(self) -> None:
        if self.recorder:
            await self.recorder.close()
        await self.http.aclose()
