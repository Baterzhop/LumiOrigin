# Lumi V4 Architecture

## Product definition

Lumi is a local-first personal AI assistant. The product goal is not to simulate consciousness; it is to reliably understand a task, retrieve grounded context, use approved tools, preserve useful memory, and explain what it did.

## Non-negotiable design rules

1. **The model is not the system.** LLM output is untrusted input to orchestration and policy layers.
2. **One canonical state store.** SQLite is the initial source of truth for conversations, tasks, tool calls, documents, chunks, and memories.
3. **No direct LLM-to-shell/file mutation.** Every side effect goes through a typed tool + policy decision.
4. **Local-first, provider-neutral.** Ollama is the first provider, not a hard dependency of the architecture.
5. **Bounded execution.** Every agent task has step, time, and tool budgets.
6. **Grounding is measurable.** RAG must return source/chunk identifiers; AI quality is evaluated separately from unit tests.
7. **No microservices until scale requires them.** V4 begins as one Python service with internal modules.

## Target flow

```text
User
 ↓
SwiftUI client
 ↓
API/session layer
 ↓
AgentRuntime
 ├─ ContextManager
 ├─ ModelGateway
 ├─ Retriever
 ├─ ToolRegistry
 ├─ PolicyEngine
 └─ EventRecorder
 ↓
SQLite + vector/FTS indexes
```

## Domain boundaries

### AgentRuntime
Owns task lifecycle: receive → plan → act → observe → finish. It must not perform file/network side effects directly.

### ModelGateway
Normalizes model providers, timeouts, metadata, fallbacks, and later streaming/tool-call formats.

### Storage
Owns migrations and durable records. Higher layers never issue ad-hoc schema mutations.

### RAG
Owns ingestion, chunk metadata, sparse+dense retrieval, rank fusion, reranking, and citations.

### Tools
Each tool exposes a typed schema, risk level, timeout, and executor. Tool proposals are evaluated by PolicyEngine before execution.

### Memory
Working context, conversation summaries, and durable semantic memories are separate data classes. Durable memory must be inspectable and deletable.

## Security model

External documents, websites, emails, and tool output are **untrusted content**. They never become system instructions. High-risk operations require explicit approval. Shell execution is sandboxed and disabled by default.

## Milestones

### M0 — Foundation (this branch)
- modular Python service
- SQLite migrations
- provider abstraction
- bounded chat runtime
- tool policy contracts
- CI

Exit gate: unit tests green on Linux/macOS and API smoke import passes.

### M1 — Streaming + native client
- SSE/WebSocket event protocol
- cancel generation
- SwiftUI networking layer
- model/runtime status UI

Exit gate: user sees token stream and can cancel without corrupting conversation state.

### M2 — Real RAG
- ingestion pipeline (PDF/Markdown/Text first)
- chunk metadata + content hashes
- SQLite FTS5/BM25
- local embeddings
- reciprocal-rank fusion
- cached reranker
- citations
- RAG eval set (Recall@k, MRR, nDCG)

Exit gate: retrieval metrics exceed defined baseline and every grounded answer can surface sources.

### M3 — Agent tools
- typed tool registry
- read-only filesystem/search tools first
- policy/approval UX
- task state machine + budgets
- tool audit log

Exit gate: tool success and denial paths covered by integration/security tests.

### M4 — Memory
- summarization by token budget
- user-approved durable memories
- semantic recall
- memory management UI

Exit gate: persistence/retrieval evals and deletion guarantees pass.

### M5 — Developer Agent
- inspect repo
- propose plan
- create branch
- modify files
- run tests
- present diff
- PR only after explicit approval

Exit gate: no direct self-modification of the running application; all changes are version-controlled and auditable.
