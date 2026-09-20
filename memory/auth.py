from __future__ import annotations

import hmac

from fastapi import HTTPException, Request, status


async def require_api_token(request: Request) -> None:
    """Require bearer auth only when the memory service has a configured token."""
    expected: str = request.app.state.settings.api_token
    if not expected:
        return
    scheme, _, supplied = request.headers.get("Authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(supplied, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Valid bearer token required",
            headers={"WWW-Authenticate": "Bearer"},
        )