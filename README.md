# Lumi V4 — Foundation

Lumi V4 is a ground-up redesign of Lumi as a local-first AI assistant platform rather than a single chat class.

This branch intentionally starts small: one Python core service, one durable SQLite store, explicit model/tool contracts, a bounded agent runtime, and a native macOS client boundary. It is a **modular monolith**, not a microservice swarm.

## Architecture

```text
macOS SwiftUI client
        │
        │ HTTP / SSE (streaming in next milestone)
        ▼
Lumi Core (Python)
  ├─ API
  ├─ Agent runtime
  ├─ Model gateway
  ├─ Memory/storage
  ├─ Tool registry + policy
  ├─ RAG contracts
  └─ Observability hooks
        │
        ├─ SQLite (canonical local state)
        └─ Ollama-compatible local model
```

## What is working in this foundation

- FastAPI core with `/health` and `/v1/chat`.
- Durable SQLite schema + migration runner.
- Conversations and messages persist across process restarts.
- Model provider abstraction with Ollama + deterministic fallback.
- Structured model metadata: provider/model/fallback/error.
- Bounded agent runtime with explicit conversation persistence.
- Tool risk policy contract (low/medium/high/critical).
- Unit tests that do not require a real model server.
- CI on Linux and macOS.

## What is deliberately not claimed yet

V4 Foundation is not yet a full autonomous agent. It does not yet include dense embeddings, reranking, document ingestion, tool execution, streaming, long-term semantic memory, or a production SwiftUI client. These are separate milestones so they can be built and evaluated instead of being hidden inside one large `LumiEngine`.

## Run

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e "services/core[dev]"
uvicorn lumi_core.api.main:app --reload --port 8790
```

Then:

```bash
curl http://127.0.0.1:8790/health
curl -X POST http://127.0.0.1:8790/v1/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello Lumi"}'
```

Optional local model:

```bash
export LUMI_OLLAMA_URL=http://127.0.0.1:11434/api/chat
export LUMI_OLLAMA_MODEL=llama3.2
```

## Test

```bash
pytest services/core/tests
```

## Repository layout

```text
apps/
  macos/                 native client boundary (next milestone)
services/
  core/
    src/lumi_core/
      agent/
      api/
      models/
      rag/
      storage/
      tools/
    tests/
docs/
  architecture.md
  adr/
.github/workflows/
```

See `docs/architecture.md` for the V4 target design and milestone gates.
