#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
from typing import Any

from fastapi import FastAPI
from fastapi.responses import StreamingResponse
import uvicorn


CHAT_MODEL = "lumi-ci-model"
EMBED_MODEL = "lumi-ci-embed"
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


def _embedding(text: str, dimensions: int = 96) -> list[float]:
    vector = [0.0] * dimensions
    for token in text.lower().split():
        digest = hashlib.sha256(token.encode("utf-8")).digest()
        index = int.from_bytes(digest[:4], "big") % dimensions
        sign = -1.0 if digest[4] & 1 else 1.0
        vector[index] += sign
    norm = math.sqrt(sum(value * value for value in vector)) or 1.0
    return [value / norm for value in vector]


@app.get("/api/tags")
def tags() -> dict[str, Any]:
    return {
        "models": [
            {"name": CHAT_MODEL, "model": CHAT_MODEL},
            {"name": EMBED_MODEL, "model": EMBED_MODEL},
        ]
    }


@app.post("/api/embed")
def embed(payload: dict[str, Any]) -> dict[str, Any]:
    values = payload.get("input", [])
    if isinstance(values, str):
        values = [values]
    if not isinstance(values, list):
        values = []
    return {"model": payload.get("model") or EMBED_MODEL, "embeddings": [_embedding(str(value)) for value in values]}


@app.post("/api/chat")
def chat(payload: dict[str, Any]):
    messages = payload.get("messages") or []
    last_user = ""
    for message in reversed(messages):
        if isinstance(message, dict) and message.get("role") == "user":
            last_user = str(message.get("content") or "")
            break
    content = "Lumi CI model response"
    if last_user:
        content += f": {last_user[:120]}"

    if not payload.get("stream"):
        return {"model": payload.get("model") or CHAT_MODEL, "message": {"role": "assistant", "content": content}, "done": True}

    def events():
        midpoint = max(1, len(content) // 2)
        for chunk in (content[:midpoint], content[midpoint:]):
            if chunk:
                yield json.dumps({"model": CHAT_MODEL, "message": {"role": "assistant", "content": chunk}, "done": False}) + "\n"
        yield json.dumps({"model": CHAT_MODEL, "message": {"role": "assistant", "content": ""}, "done": True}) + "\n"

    return StreamingResponse(events(), media_type="application/x-ndjson")


def main() -> int:
    parser = argparse.ArgumentParser(description="Deterministic Ollama-compatible server for Lumi CI")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=11435)
    args = parser.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning", access_log=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
