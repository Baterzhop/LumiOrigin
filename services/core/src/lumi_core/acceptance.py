from __future__ import annotations

import json
import uuid
from collections.abc import Callable

import httpx


class AcceptanceError(RuntimeError):
    pass


def _require(response: httpx.Response, expected: int = 200) -> dict:
    if response.status_code != expected:
        request = response.request
        raise AcceptanceError(
            f"{request.method} {request.url}: HTTP {response.status_code}: {response.text[:1000]}"
        )
    if not response.content:
        return {}
    payload = response.json()
    if not isinstance(payload, dict):
        raise AcceptanceError("expected_json_object")
    return payload


def run_acceptance(
    base_url: str,
    *,
    require_model: bool,
    api_key: str | None = None,
    timeout_seconds: float = 30.0,
    transport: httpx.BaseTransport | None = None,
) -> dict:
    """Run the installed-runtime acceptance contract against a live Lumi Core.

    The probe creates isolated memory/document/chat state, verifies the main product
    surfaces, then removes the temporary memory and knowledge document. A verified
    database backup is intentionally retained as an operational recovery check.
    """

    base = base_url.rstrip("/")
    if not base:
        raise AcceptanceError("base_url_required")
    headers = {"X-Lumi-Key": api_key} if api_key else {}
    checks: dict[str, object] = {}
    cleanup_errors: list[str] = []
    memory_id: str | None = None
    document_id: str | None = None
    conversation_ids: set[str] = set()
    chat: dict = {}
    event_types: list[str] = []

    with httpx.Client(
        base_url=base,
        headers=headers,
        timeout=timeout_seconds,
        transport=transport,
    ) as client:
        try:
            health = _require(client.get("/health"))
            if health.get("ok") is not True:
                raise AcceptanceError("health_not_ok")
            checks["health"] = True

            ready = _require(client.get("/ready"))
            if ready.get("ok") is not True:
                raise AcceptanceError("ready_not_ok")
            checks["ready"] = True

            runtime = _require(client.get("/v1/runtime"))
            if runtime.get("ok") is not True:
                raise AcceptanceError("runtime_not_ok")
            checks["runtime"] = True

            chat = _require(client.post("/v1/chat", json={"message": "Lumi acceptance probe"}))
            if not chat.get("content"):
                raise AcceptanceError("chat_empty")
            if chat.get("conversation_id"):
                conversation_ids.add(str(chat["conversation_id"]))
            if require_model and chat.get("fallback"):
                raise AcceptanceError(f"real_model_required_but_fallback_used:{chat.get('error')}")
            checks["chat"] = {
                "ok": True,
                "provider": chat.get("provider"),
                "model": chat.get("model"),
                "fallback": bool(chat.get("fallback")),
            }

            stream_conversation: str | None = None
            with client.stream(
                "POST",
                "/v1/chat/stream",
                json={"message": "Stream acceptance probe"},
            ) as response:
                if response.status_code != 200:
                    raise AcceptanceError(
                        f"stream_http_{response.status_code}:{response.read().decode(errors='replace')[:1000]}"
                    )
                for raw in response.iter_lines():
                    line = raw.strip()
                    if not line.startswith("data:"):
                        continue
                    event = json.loads(line[5:].strip())
                    if not isinstance(event, dict):
                        continue
                    event_type = str(event.get("type"))
                    event_types.append(event_type)
                    if event.get("conversation_id"):
                        stream_conversation = str(event["conversation_id"])
                    if require_model and event_type == "completed" and event.get("fallback"):
                        raise AcceptanceError(
                            f"real_model_required_but_streaming_fallback_used:{event.get('error')}"
                        )
            if stream_conversation:
                conversation_ids.add(stream_conversation)
            if "started" not in event_types or "completed" not in event_types:
                raise AcceptanceError(f"stream_event_contract_failed:{event_types}")
            checks["streaming"] = {"ok": True, "events": event_types}

            marker = f"acceptance-memory-{uuid.uuid4().hex}"
            memory = _require(
                client.post(
                    "/v1/memories",
                    json={
                        "content": f"{marker} means the acceptance test is isolated.",
                        "kind": "test",
                        "title": "Acceptance memory",
                        "approved_by_user": True,
                    },
                )
            )["memory"]
            memory_id = str(memory["id"])
            memory_search = _require(client.post("/v1/memories/search", json={"query": marker, "k": 4}))
            if not any(hit.get("memory_id") == memory_id for hit in memory_search.get("hits", [])):
                raise AcceptanceError("memory_retrieval_failed")
            checks["memory"] = True

            doc_marker = f"acceptance-doc-{uuid.uuid4().hex}"
            upload = _require(
                client.post(
                    "/v1/knowledge/upload",
                    files={
                        "file": (
                            "acceptance.txt",
                            f"{doc_marker} local grounded retrieval probe".encode(),
                            "text/plain",
                        )
                    },
                    data={"title": "Acceptance document", "source": "acceptance"},
                )
            )
            document_id = str(upload["document_id"])
            if int(upload.get("chunk_count", 0)) < 1:
                raise AcceptanceError("knowledge_ingestion_failed")
            query = _require(client.post("/v1/knowledge/query", json={"query": doc_marker, "k": 6}))
            hits = query.get("hits", [])
            if not hits or not any(hit.get("document_id") == document_id for hit in hits):
                raise AcceptanceError("knowledge_retrieval_failed")
            checks["knowledge"] = True

            tools = _require(client.get("/v1/tools"))
            if not tools.get("tools"):
                raise AcceptanceError("tool_registry_empty")
            checks["tools"] = {"ok": True, "count": len(tools["tools"])}

            backup = _require(client.post("/v1/admin/backup"))
            if backup.get("ok") is not True or not backup.get("backup"):
                raise AcceptanceError("backup_probe_failed")
            checks["backup"] = {"ok": True, "path": backup.get("backup")}
        finally:
            if memory_id:
                try:
                    response = client.delete(f"/v1/memories/{memory_id}")
                    if response.status_code not in {200, 404}:
                        cleanup_errors.append(f"memory:{response.status_code}")
                except Exception as exc:  # pragma: no cover - defensive cleanup
                    cleanup_errors.append(f"memory:{type(exc).__name__}")
            if document_id:
                try:
                    response = client.delete(f"/v1/knowledge/documents/{document_id}")
                    if response.status_code not in {200, 404}:
                        cleanup_errors.append(f"document:{response.status_code}")
                except Exception as exc:  # pragma: no cover - defensive cleanup
                    cleanup_errors.append(f"document:{type(exc).__name__}")
            for conversation_id in conversation_ids:
                try:
                    response = client.delete(f"/v1/conversations/{conversation_id}")
                    if response.status_code not in {200, 404}:
                        cleanup_errors.append(f"conversation:{response.status_code}")
                except Exception as exc:  # pragma: no cover - defensive cleanup
                    cleanup_errors.append(f"conversation:{type(exc).__name__}")

    if cleanup_errors:
        raise AcceptanceError("acceptance_cleanup_failed:" + ",".join(cleanup_errors))

    return {
        "ok": True,
        "base_url": base,
        "require_model": require_model,
        "chat_provider": chat.get("provider"),
        "chat_model": chat.get("model"),
        "fallback": bool(chat.get("fallback")),
        "stream_events": event_types,
        "checks": checks,
        "temporary_state_cleaned": True,
    }
