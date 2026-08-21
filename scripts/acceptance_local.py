#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import uuid

import httpx


def headers() -> dict[str, str]:
    key = os.getenv("LUMI_API_KEY", "").strip()
    return {"X-Lumi-Key": key} if key else {}


def require(response: httpx.Response, expected: int = 200) -> dict:
    if response.status_code != expected:
        raise RuntimeError(f"{response.request.method} {response.request.url}: HTTP {response.status_code}: {response.text[:1000]}")
    if not response.content:
        return {}
    return response.json()


def run(base_url: str, *, require_model: bool) -> None:
    base = base_url.rstrip("/")
    common_headers = headers()
    with httpx.Client(base_url=base, headers=common_headers, timeout=30.0) as client:
        health = require(client.get("/health"))
        assert health["ok"] is True
        ready = require(client.get("/ready"))
        assert ready["ok"] is True

        runtime = require(client.get("/v1/runtime"))
        assert runtime["ok"] is True

        chat = require(client.post("/v1/chat", json={"message": "Lumi acceptance probe"}))
        assert chat["content"]
        if require_model and chat.get("fallback"):
            raise RuntimeError(f"real model required but fallback was used: {chat.get('error')}")

        event_types: list[str] = []
        with client.stream("POST", "/v1/chat/stream", json={"message": "Stream acceptance probe"}) as response:
            if response.status_code != 200:
                raise RuntimeError(f"stream HTTP {response.status_code}: {response.read().decode(errors='replace')[:1000]}")
            for raw in response.iter_lines():
                line = raw.strip()
                if not line.startswith("data:"):
                    continue
                event = json.loads(line[5:].strip())
                event_types.append(str(event.get("type")))
                if require_model and event.get("type") == "completed" and event.get("fallback"):
                    raise RuntimeError(f"real model required but streaming fallback was used: {event.get('error')}")
        assert "started" in event_types
        assert "completed" in event_types

        marker = f"acceptance-memory-{uuid.uuid4().hex}"
        memory = require(
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
        memory_id = memory["id"]
        memory_search = require(client.post("/v1/memories/search", json={"query": marker, "k": 4}))
        assert any(hit["memory_id"] == memory_id for hit in memory_search["hits"])
        require(client.delete(f"/v1/memories/{memory_id}"))

        doc_marker = f"acceptance-doc-{uuid.uuid4().hex}"
        upload = require(
            client.post(
                "/v1/knowledge/upload",
                files={"file": ("acceptance.txt", f"{doc_marker} local grounded retrieval probe".encode(), "text/plain")},
                data={"title": "Acceptance document", "source": "acceptance"},
            )
        )
        assert upload["chunk_count"] >= 1
        query = require(client.post("/v1/knowledge/query", json={"query": doc_marker, "k": 6}))
        assert query["hits"], "knowledge query returned no hits"

        tools = require(client.get("/v1/tools"))
        assert tools["tools"], "tool registry is empty"

    print(
        json.dumps(
            {
                "ok": True,
                "base_url": base,
                "require_model": require_model,
                "chat_provider": chat["provider"],
                "chat_model": chat["model"],
                "stream_events": event_types,
            },
            indent=2,
            ensure_ascii=False,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Lumi V4 local acceptance test")
    parser.add_argument("--base-url", default=os.getenv("LUMI_CORE_URL", "http://127.0.0.1:8790"))
    parser.add_argument("--require-model", action="store_true")
    args = parser.parse_args()
    try:
        run(args.base_url, require_model=args.require_model)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
