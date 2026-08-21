from __future__ import annotations

import hmac
import ipaddress

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send


def _header(scope: Scope, name: bytes) -> str | None:
    for key, value in scope.get("headers", []):
        if key.lower() == name:
            return value.decode("latin-1")
    return None


def _is_loopback_client(scope: Scope) -> bool:
    client = scope.get("client")
    if not client:
        return False
    host = str(client[0]).strip()
    if host in {"testclient", "testserver", "localhost"}:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class LocalAccessMiddleware:
    """Without an API key Lumi only accepts loopback clients, even if Uvicorn is bound broadly."""

    def __init__(self, app: ASGIApp, *, api_key_configured: bool):
        self.app = app
        self.api_key_configured = api_key_configured

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and not self.api_key_configured and not _is_loopback_client(scope):
            response = JSONResponse({"detail": "remote_access_requires_api_key"}, status_code=403)
            await response(scope, receive, send)
            return
        await self.app(scope, receive, send)


class APIKeyMiddleware:
    """Protect versioned API routes when LUMI_API_KEY is configured."""

    def __init__(self, app: ASGIApp, *, api_key: str | None, protected_prefix: str = "/v1"):
        self.app = app
        self.api_key = api_key
        self.protected_prefix = protected_prefix

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or not self.api_key:
            await self.app(scope, receive, send)
            return

        path = str(scope.get("path") or "")
        if not path.startswith(self.protected_prefix):
            await self.app(scope, receive, send)
            return

        candidate = _header(scope, b"x-lumi-key")
        if not candidate:
            authorization = _header(scope, b"authorization") or ""
            if authorization.lower().startswith("bearer "):
                candidate = authorization[7:].strip()

        if not candidate or not hmac.compare_digest(candidate, self.api_key):
            response = JSONResponse(
                {"detail": "invalid_or_missing_api_key"},
                status_code=401,
                headers={"WWW-Authenticate": "Bearer"},
            )
            await response(scope, receive, send)
            return

        await self.app(scope, receive, send)
