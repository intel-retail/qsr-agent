"""Bearer-token gate for the HTTP transport: deployments must not be triggerable by any peer on the network."""

from __future__ import annotations

import hmac

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

MIN_TOKEN_CHARS = 16
OPEN_PATHS = {"/health"}


class BearerAuth:
    def __init__(self, app: ASGIApp, token: str) -> None:
        self.app = app
        self._expected = f"Bearer {token}".encode()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] in OPEN_PATHS:
            await self.app(scope, receive, send)
            return
        supplied = dict(scope["headers"]).get(b"authorization", b"")
        if hmac.compare_digest(supplied, self._expected):
            await self.app(scope, receive, send)
            return
        await JSONResponse({"error": "unauthorized"}, status_code=401,
                           headers={"WWW-Authenticate": "Bearer"})(scope, receive, send)
