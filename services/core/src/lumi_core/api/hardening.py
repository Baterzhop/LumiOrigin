from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from lumi_core.config import Settings

from .observability import RequestContextMiddleware
from .security import APIKeyMiddleware, LocalAccessMiddleware


def configure_hardening(app: FastAPI, settings: Settings) -> None:
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=list(settings.trusted_hosts))
    app.add_middleware(LocalAccessMiddleware, api_key_configured=bool(settings.api_key))
    app.add_middleware(APIKeyMiddleware, api_key=settings.api_key)
    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(settings.cors_origins),
            allow_credentials=False,
            allow_methods=["GET", "POST", "PATCH", "DELETE"],
            allow_headers=["Accept", "Content-Type", "X-Lumi-Key", "X-Request-ID"],
        )
    app.add_middleware(RequestContextMiddleware)
