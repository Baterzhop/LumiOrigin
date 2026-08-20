# Lumi V4 — Foundation + M1 + M2 + M3 + M4

Lumi V4 is a ground-up redesign of Lumi as a local-first AI assistant platform rather than a single chat class. The current branch is a modular monolith: one Python core service, durable SQLite state, grounded RAG, policy-gated tools, token-budget context management, explicit durable memory, and a native SwiftUI client.

## Working architecture

```text
macOS SwiftUI client
        │
        │ HTTP + SSE + document upload + approvals + memory CRUD
        ▼
Lumi Core (Python)
  ├─ API + generation registry
  ├─ Chat runtime
  │   ├─ token-budget ContextManager
  │   ├─ compact conversation summaries
  │   ├─ durable-memory recall
  │   └─ grounded RAG context
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
  ├─ Memory
  │   ├─ explicit approved records
  │   ├─ SQLite FTS5 recall
  │   ├─ optional local embeddings
  │   ├─ weighted RRF fusion
  │   └─ inspect/edit/delete UI
  └─ SQLite storage + migrations
        │
        ├─ SQLite canonical state
        ├─ sandboxed Lumi workspace
        └─ Ollama-compatible local models
```

## What works now

- FastAPI health/runtime/chat/stream/knowledge/task/tool/memory APIs.
- Real SSE generation with explicit cancellation.
- Native SwiftUI client with streaming chat, grounded citations, memory management, agent controls, and approval UX.
- Durable conversations/messages/tasks/tool calls with status and audit metadata.
- Recent conversation context is bounded by estimated tokens, not raw message count.
- Older dialogue can be compacted into a persisted summary; a deterministic extractive fallback is used if the local model cannot summarize.
- Durable memory is created only through an explicit user-approved action and is inspectable, editable, and hard-deletable.
- Memory recall uses SQLite FTS5 plus optional local embeddings with weighted Reciprocal Rank Fusion.
- Recalled memory is shown separately from document citations in the macOS client.
- PDF, Markdown and text knowledge import with hash deduplication and deterministic chunk IDs.
- SQLite FTS5 sparse RAG retrieval plus optional Ollama dense embeddings.
- Weighted Reciprocal Rank Fusion and optional lazy CrossEncoder reranking.
- Typed tool registry with strict JSON argument schemas and per-tool timeouts.
- Sandboxed `workspace.list_files`, `workspace.read_text`, `workspace.search_text`, and `knowledge.search` tools.
- `workspace.write_text` is high-risk and cannot execute until the user approves the exact proposed arguments.
- Absolute paths and workspace escapes are rejected; shell/delete tools are not exposed.
- Task execution is bounded by step, tool-call, and wall-clock budgets.
- Tool outputs, retrieved documents, summaries, and recalled memory have explicit trust boundaries.
- Deterministic RAG and memory retrieval regression gates run in CI.
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

Context and memory controls:

```bash
export LUMI_CONTEXT_MAX_INPUT_TOKENS=6000
export LUMI_CONTEXT_RECENT_TOKENS=3500
export LUMI_CONTEXT_SUMMARY_TOKENS=800
export LUMI_MEMORY_RECALL_K=4
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
python scripts/eval_memory.py --assert-thresholds
cd apps/macos && swift test
```

See `docs/architecture.md`, `docs/event-protocol.md`, `docs/rag.md`, `docs/tools.md`, and `docs/memory.md` for design contracts and current limitations.
