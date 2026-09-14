"""Background jobs for the slow, one-title-at-a-time recorder operations (bulk delete, bulk protect, duplicate scan).

A job runs as an asyncio task; the API answers 202 with the job and the client polls GET /jobs/{id}. Between
items the job checks whether it was cancelled and stops there: work already done stays done, nothing more
is touched, and the result reports how far it got.
"""
from __future__ import annotations

import asyncio
import logging
import secrets
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("bdzbridge.jobs")


class JobCancelled(Exception):
    """Raised inside a job body by `Job.checkpoint()` once cancellation was requested."""


@dataclass
class Job:
    id: str
    kind: str  # delete | protect | duplicates
    total: int = 0
    done: int = 0
    finished: bool = False
    cancelled: bool = False
    error: str | None = None
    result: dict[str, Any] = field(default_factory=dict)

    def checkpoint(self) -> None:
        """Call between items: stops the job if a cancel request came in."""
        if self.cancelled:
            raise JobCancelled

    def step(self) -> None:
        self.done += 1
        self.checkpoint()

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "kind": self.kind, "total": self.total, "done": self.done, "finished": self.finished,
                "cancelled": self.cancelled, "error": self.error, "result": self.result}


class Jobs:
    """Registry of running and recently finished jobs."""

    def __init__(self, keep: int = 30):
        self._jobs: dict[str, Job] = {}
        self._keep = keep

    def get(self, job_id: str) -> Job | None:
        return self._jobs.get(job_id)

    def all(self) -> list[Job]:
        """Unfinished jobs first (oldest first), then the recently finished ones, newest first."""
        jobs = list(self._jobs.values())
        return [j for j in jobs if not j.finished] + [j for j in reversed(jobs) if j.finished]

    def start(self, kind: str, body: Callable[[Job], Awaitable[None]], total: int = 0, result: dict | None = None) -> Job:
        job = Job(id=secrets.token_hex(4), kind=kind, total=total, result=result or {})
        self._jobs[job.id] = job
        finished = [k for k, j in self._jobs.items() if j.finished]
        for k in finished[:-self._keep]:
            del self._jobs[k]
        asyncio.create_task(self._run(job, body))
        return job

    async def _run(self, job: Job, body: Callable[[Job], Awaitable[None]]) -> None:
        try:
            await body(job)
        except JobCancelled:
            log.info("job %s (%s) cancelled after %d of %d", job.id, job.kind, job.done, job.total)
        except Exception as e:
            job.error = str(e) or type(e).__name__  # httpx timeouts carry no message
            log.warning("job %s (%s) failed: %s", job.id, job.kind, e)
        finally:
            job.finished = True

    def cancel(self, job_id: str) -> Job | None:
        job = self._jobs.get(job_id)
        if job and not job.finished:
            job.cancelled = True
        return job
