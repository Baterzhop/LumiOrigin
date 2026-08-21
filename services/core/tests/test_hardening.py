from __future__ import annotations

import os

import httpx
import pytest
from fastapi import FastAPI

from lumi_core.api.security import APIKeyMiddleware, LocalAccessMiddleware
from lumi_core.config import Settings
from lumi_core.storage.database import Database
from lumi_core.storage.maintenance import DatabaseMaintenance


def _clear_lumi_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in list(os.environ):
        if name.startswith("LUMI_"):
            monkeypatch.delenv(name, raising=False)


def test_settings_validate_and_hide_secrets(monkeypatch, tmp_path):
    _clear_lumi_env(monkeypatch)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("LUMI_API_KEY", "a" * 32)
    monkeypatch.setenv("LUMI_DEV_GITHUB_TOKEN", "secret-token-do-not-render")
    settings = Settings.from_env()
    rendered = repr(settings)
    assert "a" * 32 not in rendered
    assert "secret-token-do-not-render" not in rendered
    assert settings.api_key == "a" * 32


def test_settings_reject_short_api_key(monkeypatch, tmp_path):
    _clear_lumi_env(monkeypatch)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("LUMI_API_KEY", "too-short")
    with pytest.raises(ValueError, match="at least 24"):
        Settings.from_env()


def test_settings_reject_wildcard_host_without_key(monkeypatch, tmp_path):
    _clear_lumi_env(monkeypatch)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("LUMI_TRUSTED_HOSTS", "*")
    with pytest.raises(ValueError, match="wildcard trusted hosts"):
        Settings.from_env()


@pytest.mark.asyncio
async def test_remote_client_is_blocked_when_no_api_key():
    app = FastAPI()
    app.add_middleware(LocalAccessMiddleware, api_key_configured=False)

    @app.get("/health")
    async def health():
        return {"ok": True}

    transport = httpx.ASGITransport(app=app, client=("10.1.2.3", 4321))
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
        response = await client.get("/health")
    assert response.status_code == 403
    assert response.json()["detail"] == "remote_access_requires_api_key"


@pytest.mark.asyncio
async def test_api_key_protects_v1_but_not_health():
    app = FastAPI()
    app.add_middleware(APIKeyMiddleware, api_key="k" * 32)

    @app.get("/health")
    async def health():
        return {"ok": True}

    @app.get("/v1/private")
    async def private():
        return {"ok": True}

    transport = httpx.ASGITransport(app=app, client=("127.0.0.1", 1234))
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as client:
        assert (await client.get("/health")).status_code == 200
        assert (await client.get("/v1/private")).status_code == 401
        authorized = await client.get("/v1/private", headers={"X-Lumi-Key": "k" * 32})
    assert authorized.status_code == 200


def test_database_backup_is_consistent_and_prunable(tmp_path):
    database = Database(tmp_path / "lumi.sqlite3")
    database.migrate()
    conversation_id = database.create_conversation("backup probe")
    database.add_message(conversation_id, "user", "persist me")

    maintenance = DatabaseMaintenance(database)
    ok, detail = maintenance.integrity_check(full=True)
    assert ok is True
    assert detail == "ok"

    backup_dir = tmp_path / "backups"
    first = maintenance.create_backup(backup_dir)
    second = maintenance.create_backup(backup_dir)
    assert first.exists() and second.exists()

    backup_database = Database(first)
    assert backup_database.conversation_exists(conversation_id)
    assert backup_database.list_messages(conversation_id)[0]["content"] == "persist me"

    removed = maintenance.prune_backups(backup_dir, keep=1)
    assert len(removed) == 1
    assert len(list(backup_dir.glob("lumi-*.sqlite3"))) == 1
