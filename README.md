# Lumi V4 — Foundation + M1 + M2

Lumi V4 is a ground-up redesign of Lumi as a local-first AI assistant platform rather than a single chat class. The current branch is a modular monolith: one Python core service, durable SQLite state, explicit model/tool contracts, and a native SwiftUI client.

## Working architecture

```text
macOS SwiftUI client
        │
        │ HTTP + SSE + document upload
        ▼
Lumi Core (Python)
  ├─ API + generation registry
  ├─ Agent runtime
  ├─ Model gateway
  ├─ RAG
  │   ├─ PDF / Markdown / Text ingestion
  │   ├─ SQLite FTS5 sparse retrieval
  │   ├─ Ollama dense embeddings
  │   ├─ weighted RRF fusion
  │   ├─ optional cached CrossEncoder reranker
  │   └─ structured citations
  ├─ SQLite storage + migrations
  └─ Tool policy contracts
        │
        ├─ SQLite canonical state
        └─ Ollama-compatible local models
```

## What works now

- FastAPI core with health/runtime/chat/stream APIs.
- Real SSE generation with explicit cancellation.
- Native SwiftUI client with streaming chat and Stop control.
- Durable conversations/messages with provider/model/finish metadata.
- PDF, Markdown and text knowledge import.
- Content-hash deduplication and deterministic chunk IDs.
- SQLite FTS5 sparse retrieval.
- Dense embeddings via Ollama `/api/embed` (default model `embeddinggemma`).
- Weighted Reciprocal Rank Fusion instead of mixing incompatible raw score scales.
- Optional lazy cached sentence-transformers CrossEncoder reranker.
- Structured citations returned by the API and displayed in the macOS client.
- Retrieval context is explicitly treated as untrusted data, not system instructions.
- Baseline Recall@k, reciprocal-rank and nDCG metrics.
- Python tests on Linux/macOS plus Swift build/tests in CI.

## Run Lumi Core

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e "services/core[dev]"
uvicorn lumi_core.api.main:app --reload --port 8790
```

Optional local models:

```bash
export LUMI_OLLAMA_URL=http://127.0.0.1:11434/api/chat
export LUMI_OLLAMA_MODEL=llama3.2
export LUMI_OLLAMA_EMBED_URL=http://127.0.0.1:11434/api/embed
export LUMI_EMBEDDING_MODEL=embeddinggemma
```

To enable the optional CrossEncoder reranker:

```bash
python -m pip install -e "services/core[rerank]"
export LUMI_RERANKER_MODEL=<cross-encoder-model>
```

## Run macOS client

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

See `docs/architecture.md`, `docs/event-protocol.md`, and `docs/rag.md` for design contracts and current limitations.
