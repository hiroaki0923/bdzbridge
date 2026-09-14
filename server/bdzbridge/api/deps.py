"""FastAPI dependencies: bearer-token auth and access to the application state."""
from __future__ import annotations

from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from ..state import Bridge

bearer = HTTPBearer(auto_error=False)


def bridge_of(request: Request) -> Bridge:
    return request.app.state.bridge


async def auth(request: Request, creds: HTTPAuthorizationCredentials | None = Depends(bearer)) -> None:
    if creds is None or creds.credentials != bridge_of(request).settings.api_token:
        raise HTTPException(401, "invalid token")
