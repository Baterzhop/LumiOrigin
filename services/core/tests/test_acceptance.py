from __future__ import annotations

import json

import httpx
import pytest

from lumi_core.acceptance import AcceptanceError, run_acceptance


def _transport(*, fallback: bool = False) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers.get("X-Lumi-Key") == "test-secret-key"
        path = request.url.path
        if request.method == "GET" and path == "/health":
            return httpx.Response(200, json={"ok": True, "version": "test"})
        if request.method == "GET" and path == "/ready":
            return httpx.Response(200, json={"ok": True})
        if request.method == "GET" and path == "/v1/runtime":
            return httpx.Response(200, json={"ok": True})
        if request.method == "POST" and path == "/v1/chat":
            return httpx.Response(
                200,
                json={
                    "conversation_id": "lumi-acceptance",
                    "message_id": "m1",
                    "content": "pong",
                    "provider": "ollama",
                    "model": "test-model",
                    "fallback": fallback,
                    "error": "offline" if fallback else None,
                },
            )
        if request.method == "POST" and path == "/v1/chat/stream":
            events = [
                {"type": "started", "generation_id": "g1", "conversation_id": "lumi-acceptance"},
                {
                    "type": "completed",
                    "generation_id": "g1",
                    "conversation_id": "lumi-acceptance",
                    "content": "pong",
                    "provider": "ollama",
                    "model": "test-model",
                    "fallback": fallback,
                    "error": "offline" if fallback else None,
                },
            ]
            body = "".join(f"data: {json.dumps(event)}\n\n" for event in events)
            return httpx.Response(200, text=body, headers={"content-type": "text/event-stream"})
        if request.method == "POST" and path == "/v1/memories":
            return httpx.Response(200, json={"memory": {"id": "mem-1"}})
        if request.method == "POST" and path == "/v1/memories/search":
            return httpx.Response(200, json={"hits": [{"memory_id": "mem-1"}]})
        if request.method == "DELETE" and path == "/v1/memories/mem-1":
            return httpx.Response(200, json={"ok": True})
        if request.method == "POST" and path == "/v1/knowledge/upload":
            return httpx.Response(
                200,
                json={
                    "document_id": "doc-1",
                    "chunk_count": 1,
                    "deduplicated": True,
                },
            )
        if request.method == "POST" and path == "/v1/knowledge/query":
            return httpx.Response(200, json={"hits": [{"document_id": "doc-1"}]})
        if request.method == "GET" and path == "/v1/tools":
            return httpx.Response(200, json={"tools": [{"name": "workspace.read_text"}]})
        if request.method == "POST" and path == "/v1/admin/backup":
            return httpx.Response(200, json={"ok": True, "backup": "/tmp/lumi-backup.sqlite3"})
        return httpx.Response(404, json={"detail": "not_found"})

    return httpx.MockTransport(handler)


def test_acceptance_contract_succeeds_and_reports_model() -> None:
    result = run_acceptance(
        "http://lumi.test",
        require_model=True,
        api_key="test-secret-key",
        transport=_transport(),
    )
    assert result["ok"] is True
    assert result["fallback"] is False
    assert result["chat_model"] == "test-model"
    assert result["checks"]["knowledge"]["deduplicated"] is True
    assert result["checks"]["backup"]["ok"] is True


def test_acceptance_contract_fails_closed_when_real_model_required() -> None:
    with pytest.raises(AcceptanceError, match="real_model_required_but_fallback_used"):
        run_acceptance(
            "http://lumi.test",
            require_model=True,
            api_key="test-secret-key",
            transport=_transport(fallback=True),
        )
