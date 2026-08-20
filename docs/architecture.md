# Lumi V4 Architecture

## Product definition

Lumi is a local-first personal AI assistant. The goal is not to simulate consciousness; it is to reliably understand a task, retrieve grounded context, use approved tools, preserve useful memory, and explain what it did.

## Non-negotiable design rules

1. **The model is not the system.** LLM output is untrusted input to orchestration and policy layers.
2. **One canonical state store.** SQLite is the initial source of truth for conversations, tasks, tool calls, documents, chunks, and memories.
3. **No direct LLM-to-shell/file mutation.** Every side effect goes through a typed tool + policy decision.
4. **Local-first, provider-neutral.** Ollama is the first provider, not a hard dependency of the architecture.
5. **Bounded execution.** Every agent task has step, time, and tool budgets.
6. **Grounding is measurable.** RAG returns source/chunk identifiers; AI quality is evaluated separately from unit tests.
7. **No microservices until scale requires them.** V4 begins as one Python service with internal modules.

## Current flow

```text
User
 ↓
SwiftUI client
 ↓
API/session layer
 ├─────────────── ChatRuntime ───────────────┐
 │                                            │
 └─ TaskRuntime                               │
      ├─ LLMTaskPlanner                       │
      ├─ ToolRegistry                         │
      ├─ PolicyEngine                         │
      ├─ budgets                              │
      └─ approval boundary                    │
              │                               │
              ├─ read-only tools              │
              └─ approved side effects        │
                                              │
              Retriever ← RAG ────────────────┤
                                              │
              ModelGateway ← Ollama ──────────┘
                      │
                      ▼
          SQLite + FTS/vector state
```

## Domain boundaries

### ChatRuntime
Owns conversational generation, retrieval context, citations, streaming, and cancellation. Chat does not execute tools implicitly.

### TaskRuntime
Owns task lifecycle: receive → plan → act → observe → finish. It enforces step/time/tool budgets and persists every proposed tool call. It never bypasses PolicyEngine.

### ModelGateway
Normalizes model providers, timeouts, metadata, fallbacks, and streaming formats. Agent planning fails closed if the planner output is malformed.

### Storage
Owns migrations and durable records. Higher layers never issue ad-hoc schema mutations.

### RAG
Owns ingestion, chunk metadata, sparse+dense retrieval, rank fusion, reranking, citations, and retrieval evaluation.

### Tools
Each tool exposes a typed Pydantic argument schema, risk level, timeout, side-effect flag, and executor. Tool proposals are evaluated before execution and audited after execution.

### Memory
Working context, conversation summaries, and durable semantic memories are separate data classes. Durable memory must be inspectable and deletable.

## Security model

External documents, websites, emails, tool output, and model-generated tool arguments are **untrusted content**. They never become system instructions.

The M3 workspace tools resolve every path against a dedicated configured root after symlink resolution. Absolute paths and parent traversal outside that root are rejected. Read operations are size-bounded. `workspace.write_text` is the only mutating tool in M3 and requires explicit approval of the displayed arguments. Delete and shell tools are not registered. Critical tools are disabled by policy even if a caller attempts to confirm them.

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

Exit gate: deterministic retrieval regression stays above repository thresholds and retrieved answers can surface structured sources. A larger representative benchmark remains required before beta.

### M3 — Agent tools — functional alpha implemented
- typed ToolRegistry + JSON argument schemas
- sandboxed list/read/search tools
- knowledge search tool
- one approval-gated text-write tool
- PolicyEngine and informed approval UX
- durable task state machine
- step/time/tool-call budgets
- tool timeouts, audit records, denial and error states
- strict JSON LLM planner
- API + Swift task/approval transport

Exit gate: success, denial, timeout, malformed-argument, sandbox-escape, approval, budget, API, Swift build and transport tests pass in CI. Local model planning still requires a physical Ollama acceptance test.

### M4 — Memory — next
- summarization by token budget
- user-approved durable memories
- semantic recall
- memory management UI
- deletion/export guarantees

Exit gate: persistence/retrieval evals, token-budget behavior, approval semantics, and deletion guarantees pass.

### M5 — Developer Agent
- inspect repo
- propose plan
- create branch
- modify files
- run tests
- present diff
- PR only after explicit approval

Exit gate: no direct self-modification of the running application; all changes are version-controlled and auditable.
