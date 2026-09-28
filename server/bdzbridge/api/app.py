"""The FastAPI application: lifespan, routers, and the built web app."""
from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from ..config import Settings
from ..services import epg as epg_service
from ..services import session
from ..state import Bridge
from ..store import Store
from .routers import guide, jobs, recorder, reservations, rules, titles

log = logging.getLogger("bdzbridge")


def create_app(settings: Settings | None = None, bridge: Bridge | None = None) -> FastAPI:
    settings = settings or Settings()
    settings.ensure_token()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        b = bridge
        if b is None:
            settings.ensure_db_dir()
            b = Bridge(settings, None, Store(settings.db_path))
            try:
                await session.resolve_recorder(b)
            except Exception:
                # A recorder that cannot be found is no reason not to serve: the guide cache is still there
                # to read, and the web app can look for the recorder and pick it again.
                log.exception("could not select a recorder at startup; starting unconfigured")
        app.state.bridge = b
        task = asyncio.create_task(epg_service.refresh_loop(b)) if bridge is None else None
        try:
            yield
        finally:
            if task:
                task.cancel()
            if bridge is None:
                await b.close()

    app = FastAPI(title="bdzbridge", version="0.1.0", lifespan=lifespan)
    for r in (recorder, guide, reservations, rules, titles, jobs):
        app.include_router(r.router)

    static_dir = Path(settings.static_dir) if settings.static_dir else Path(__file__).resolve().parents[3] / "web" / "dist"
    if static_dir.is_dir():
        # The built PWA. Mounted last so /api/* keeps precedence; same origin means no CORS.
        app.mount("/", StaticFiles(directory=str(static_dir), html=True), name="web")
        log.info("serving web app from %s", static_dir)
    return app
