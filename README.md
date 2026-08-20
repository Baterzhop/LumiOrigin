# Lumi V4 — Foundation + M1

Lumi V4 is a ground-up redesign of Lumi as a local-first AI assistant platform rather than a single chat class.

The current branch is a **modular monolith**: one Python core service, durable SQLite state, explicit model/tool contracts, and a native SwiftUI client. AI orchestration stays outside the UI process.

## Architecture

```text
macOS SwiftUI client
        │
        │ HTTP + SSE
        ▼
Lumi Core (Python)
  ├─ API + generation registry
  ├─ Agent runtime
  ├─ Model gateway
  ├─ Memory/storage
  ├─ Tool policy contracts
  ├─ RAG contracts
  └─ Observability hooks
        │
        ├─ SQLite (canonical local state)
        └─ Ollama-compatible local model
```

## What works now

- FastAPI core with `/health`, `/v1/runtime`, `/v1/chat`, and `/v1/chat/stream`.
- Real SSE token streaming from Ollama-compatible providers.
- Structured stream lifecycle: `started → delta* → completed|cancelled|error`.
- Generation cancellation through `/v1/generations/{id}/cancel`.
- Visible partial assistant output is persisted safely when cancellation occurs.
- Durable SQLite schema + migration runner.
- Provider/model/fallback/error/finish metadata stored with assistant messages.
- Native SwiftUI macOS client with streaming chat, Stop control, runtime/model status, and conversation IDs.
- Separate `LumiClientCore` Swift transport module with tests.
- Tool risk policy contract (low/medium/high/critical).
- CI on Linux and macOS, including Python tests, API SSE integration test, Swift build, and Swift tests.

## Not claimed yet

V4 is not yet a full autonomous agent. Dense embeddings, reranking, document ingestion, citations, real tool execution, long-term semantic memory, context budgeting, and agent planning remain separate milestones.

## Run Lumi Core

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e "services/core[dev]"
uvicorn lumi_core.api.main:app --reload --port 8790
```

Optional local model:

```bash
export LUMI_OLLAMA_URL=http://127.0.0.1:11434/api/chat
export LUMI_OLLAMA_MODEL=llama3.2
```

Streaming smoke request:

```bash
curl -N -X POST http://127.0.0.1:8790/v1/chat/stream \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello Lumi"}'
```

## Run the macOS client

With Lumi Core already running:

```bash
cd apps/macos
swift run LumiDesktop
```

Or open `apps/macos/Package.swift` in Xcode.

## Test

```bash
pytest services/core/tests
cd apps/macos && swift test
```

See `docs/architecture.md` for the roadmap and `docs/event-protocol.md` for the M1 transport contract.
