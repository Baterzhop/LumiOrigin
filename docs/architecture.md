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
Normalizes model providers, timeouts, metadata, fallbacks, and streaming formats.

### Storage
Owns migrations and durable records. Higher layers never issue ad-hoc schema mutations.

### RAG
Owns ingestion, chunk metadata, sparse+dense retrieval, rank fusion, reranking, citations, and retrieval evaluation.

### Tools
Each tool exposes a typed schema, risk level, timeout, and executor. Tool proposals are evaluated by PolicyEngine before execution.

### Memory
Working context, conversation summaries, and durable semantic memories are separate data classes. Durable memory must be inspectable and deletable.

## Security model

External documents, websites, emails, and tool output are **untrusted content**. They never become system instructions. High-risk operations require explicit approval. Shell execution is sandboxed and disabled by default.

## Milestones

### M0 — Foundation — implemented
- modular Python service
- SQLite migrations
- provider abstraction
- bounded chat runtime
- tool policy contracts
- CI

Exit gate: passed on Linux/macOS.

### M1 — Streaming + native client — implemented
- SSE event protocol
- cancel generation
- SwiftUI networking layer
- model/runtime status UI
- tested Swift transport package

Exit gate: backend lifecycle and client transport/build tests pass. A physical local Ollama/macOS end-to-end session remains a machine-specific acceptance test.

### M2 — Grounded RAG — functional alpha implemented
- PDF/Markdown/Text ingestion
- content hashes + deterministic chunk IDs
- SQLite FTS5 sparse retrieval
- Ollama local embeddings
- weighted reciprocal-rank fusion
- optional cached CrossEncoder reranker
- structured citations in API and SwiftUI
- prompt-injection trust boundary for retrieved data
- Recall@k / MRR / nDCG metrics
- deterministic CI regression corpus and thresholds

Exit gate: deterministic retrieval regression must stay above repository thresholds and every retrieved answer can surface structured sources. This gate protects plumbing/regressions; it is **not** evidence that RAG quality is proven on real-world data. A larger representative benchmark is required before beta.

### M3 — Agent tools — next
- typed tool registry
- read-only filesystem/search tools first
- policy/approval UX
- task state machine + step/time/tool budgets
- tool audit log

Exit gate: tool success, denial, timeout, malformed-argument, and approval paths covered by integration/security tests.

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
