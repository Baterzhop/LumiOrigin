# Lumi V4 Architecture

## Product definition

Lumi is a local-first personal AI assistant. The goal is not to simulate consciousness; it is to reliably understand a task, retrieve grounded context, use approved tools, preserve useful memory, and explain what it did.

## Non-negotiable design rules

1. **The model is not the system.** LLM output is untrusted input to orchestration and policy layers.
2. **One canonical state store.** SQLite is the initial source of truth for conversations, tasks, tool calls, documents, chunks, memories, and compact summaries.
3. **No direct LLM-to-shell/file mutation.** Every side effect goes through a typed tool + policy decision.
4. **Local-first, provider-neutral.** Ollama is the first provider, not a hard dependency of the architecture.
5. **Bounded execution.** Agent tasks have step/time/tool budgets and chat context has a token budget.
6. **Grounding is measurable.** RAG and durable-memory retrieval have deterministic regression gates in addition to unit tests.
7. **No microservices until scale requires them.** V4 remains one Python service with explicit internal boundaries.

## Current flow

```text
User
 ↓
SwiftUI client
 ↓
API/session layer
 ├──────────── ChatRuntime ─────────────────────────────┐
 │        ├─ ContextManager                             │
 │        │   ├─ recent token-budget context            │
 │        │   └─ compact conversation summary           │
 │        ├─ durable Memory recall                      │
 │        └─ grounded RAG                               │
 │                                                       │
 └─ TaskRuntime                                         │
      ├─ LLMTaskPlanner                                 │
      ├─ ToolRegistry                                   │
      ├─ PolicyEngine                                   │
      ├─ budgets                                        │
      └─ approval boundary                              │
              │                                         │
              ├─ read-only tools                        │
              └─ approved side effects                  │
                                                        │
              ModelGateway ← Ollama ────────────────────┘
                      │
                      ▼
          SQLite + FTS/vector state
```

## Domain boundaries

### ChatRuntime
Owns conversational generation, RAG context, durable-memory recall, streaming, and cancellation. Chat does not execute tools implicitly.

### ContextManager
Selects recent dialogue by estimated token budget and compacts older turns into a persisted conversation summary. Summaries are context, not authority. When the model is unavailable, compaction degrades to a deterministic extractive fallback.

### TaskRuntime
Owns task lifecycle: receive → plan → act → observe → finish. It enforces step/time/tool budgets and persists every proposed tool call. It never bypasses PolicyEngine.

### ModelGateway
Normalizes model providers, timeouts, metadata, fallbacks, and streaming formats. Agent planning fails closed if the planner output is malformed.

### Storage
Owns migrations and durable records. SQLite is the canonical store.

### RAG
Owns ingestion, chunk metadata, sparse+dense retrieval, rank fusion, reranking, citations, and retrieval evaluation.

### Tools
Each tool exposes a typed Pydantic argument schema, risk level, timeout, side-effect flag, and executor. Tool proposals are evaluated before execution and audited after execution.

### Memory
Durable memory is separate from raw conversation history and summaries. A durable item is created only by an explicit user-approved API/UI action. It is searchable through FTS5 and, when available, local embeddings with weighted reciprocal-rank fusion. Items are inspectable, editable, and hard-deletable.

## Security model

External documents, websites, emails, tool output, model-generated tool arguments, conversation summaries, and retrieved memory are context with explicit trust boundaries; none can override system policy.

Workspace tools resolve every path against a dedicated configured root after symlink resolution. Absolute paths and parent traversal outside that root are rejected. `workspace.write_text` requires explicit approval of displayed arguments. Delete and shell tools are not registered. Critical tools are disabled by policy.

Durable memory is never inferred and persisted silently in M4. The agent tool registry exposes no autonomous memory-write tool. Chat can only recall records that were deliberately saved by the user.

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

Exit gate: backend lifecycle and client transport/build tests pass. A physical local Ollama/macOS end-to-end session remains machine-specific.

### M2 — Grounded RAG — functional alpha implemented
- PDF/Markdown/Text ingestion
- content hashes + deterministic chunk IDs
- SQLite FTS5 sparse retrieval
- Ollama local embeddings
- weighted reciprocal-rank fusion
- optional cached CrossEncoder reranker
- structured citations in API and SwiftUI
- prompt-injection trust boundary
- Recall@k / MRR / nDCG metrics
- deterministic CI regression corpus

Exit gate: deterministic retrieval regression stays above repository thresholds. A larger representative benchmark remains required before beta.

### M3 — Agent tools — functional alpha implemented
- typed ToolRegistry + strict JSON schemas
- sandboxed list/read/search tools
- knowledge search tool
- approval-gated text-write tool
- PolicyEngine and informed approval UX
- durable task state machine
- step/time/tool-call budgets
- timeouts, audit records, denial/error states
- strict JSON LLM planner
- API + Swift task/approval transport

Exit gate: success, denial, timeout, malformed-argument, sandbox-escape, approval, budget, API, Swift build and transport tests pass in CI. Local-model planning still requires a physical Ollama acceptance test.

### M4 — Durable memory + context management — functional alpha implemented
- recent dialogue selected by token budget rather than raw message count
- persisted compact summaries for older conversation history
- deterministic summary fallback if the local model is offline
- explicit user-approved durable memories only
- FTS5 + optional local semantic recall with weighted RRF
- memory CRUD API and native macOS management UI
- recalled memories surfaced separately from RAG citations
- deterministic memory retrieval regression gate
- hard-deletion tests covering record, FTS, and embedding state

Exit gate: token-budget behavior, persistence, retrieval regression thresholds, explicit-approval semantics, Swift transport/build, and deletion guarantees pass in CI. Representative multilingual/long-horizon memory quality remains required before beta.

### M5 — Developer Agent — next
- inspect repo
- propose plan
- create branch
- modify files
- run tests
- present diff
- PR only after explicit approval

Exit gate: no direct self-modification of the running application; all changes are version-controlled and auditable.
