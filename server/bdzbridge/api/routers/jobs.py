"""Background jobs: progress and cancellation."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request

from .. import schemas as S
from ..deps import auth, bridge_of

router = APIRouter(prefix="/api/v1", tags=["jobs"], dependencies=[Depends(auth)])


@router.get("/jobs/{job_id}", response_model=S.Job)
async def job_status(request: Request, job_id: str):
    """Progress and, once finished, the result of a bulk job."""
    job = bridge_of(request).jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "unknown job")
    return job.to_dict()


@router.post("/jobs/{job_id}/cancel", response_model=S.Job)
async def job_cancel(request: Request, job_id: str):
    """Stop after the item being processed; what is done stays done."""
    job = bridge_of(request).jobs.cancel(job_id)
    if job is None:
        raise HTTPException(404, "unknown job")
    return job.to_dict()
