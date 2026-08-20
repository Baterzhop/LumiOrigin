# Lumi V4 — Foundation + M1 + M2 + M3

Lumi V4 is a ground-up redesign of Lumi as a local-first AI assistant platform rather than a single chat class. The current branch is a modular monolith: one Python core service, durable SQLite state, grounded RAG, policy-gated tools, and a native SwiftUI client.

## Working architecture

```text
macOS SwiftUI client
        │
        │ HTTP + SSE + document upload + approvals
        ▼
Lumi Core (Python)
  ├─ API + generation registry
  ├─ Chat runtime
  ├─ Bounded task runtime
  │   ├─ LLM planner
  │   ├─ ToolRegistry
  │   ├─ PolicyEngine
  │   ├─ step/time/tool budgets
  │   └─ durable audit log
  ├─ Model gateway
  ├─ RAG
  │   ├─ PDF / Markdown / Text ingestion
  │   ├─ SQLite FTS5 sparse retrieval
  │   ├─ Ollama dense embeddings
  │   ├─ weighted RRF fusion
  │   ├─ optional cached CrossEncoder reranker
  │   └─ structured citations
  └─ SQLite storage + migrations
        │
        ├─ SQLite canonical state
        ├─ sandboxed Lumi workspace
        └─ Ollama-compatible local models
```

## What works now

- FastAPI health/runtime/chat/stream/knowledge/task/tool APIs.
- Real SSE generation with explicit cancellation.
- Native SwiftUI client with streaming chat, grounded citations, agent-task controls, and approval UX.
- Durable conversations/messages/tasks/tool calls with status and audit metadata.
- PDF, Markdown and text knowledge import.
- Content-hash deduplication and deterministic chunk IDs.
- SQLite FTS5 sparse retrieval plus optional Ollama dense embeddings.
- Weighted Reciprocal Rank Fusion and optional lazy CrossEncoder reranking.
- Structured citations shown in the macOS client.
- Typed tool registry with JSON argument schemas and per-tool timeouts.
- Sandboxed `workspace.list_files`, `workspace.read_text`, `workspace.search_text`, and `knowledge.search` tools.
- `workspace.write_text` is high-risk and cannot execute until the user approves the exact proposed arguments.
- Absolute paths and workspace escapes are rejected; shell/delete tools are not exposed.
- Task execution is bounded by step, tool-call, and wall-clock budgets.
- Tool outputs and retrieved content are explicitly treated as untrusted data.
- Recall@k, reciprocal-rank and nDCG RAG metrics plus deterministic CI regression thresholds.
- Python unit/API/security tests on Linux/macOS plus Swift build/tests in CI.

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

Tool workspace defaults to `.lumi-data/workspace`. Override it explicitly if needed:

```bash
export LUMI_TOOL_WORKSPACE="$HOME/LumiWorkspace"
```

The autonomous task planner requires a working chat model. If Ollama is unavailable, ordinary chat can fall back, but agent planning fails closed rather than guessing tool calls.

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
python scripts/eval_rag.py --assert-thresholds
cd apps/macos && swift test
```

See `docs/architecture.md`, `docs/event-protocol.md`, `docs/rag.md`, and `docs/tools.md` for design contracts and current limitations.
