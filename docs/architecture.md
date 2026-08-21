# Lumi V4 Architecture

## Product definition

Lumi is a local-first personal AI assistant. The goal is not to simulate consciousness; it is to reliably understand a task, retrieve grounded context, use approved tools, preserve useful memory, and explain what it did.

## Non-negotiable design rules

1. **The model is not the system.** LLM output is untrusted input to orchestration and policy layers.
2. **One canonical state store.** SQLite is the initial source of truth for conversations, tasks, tool calls, documents, chunks, memories, summaries, and developer-workflow audit state.
3. **No direct LLM-to-shell/file mutation.** Every side effect goes through a typed, validated boundary and explicit policy/approval when required.
4. **Local-first, provider-neutral.** Ollama is the first provider, not a hard dependency of the architecture.
5. **Bounded execution.** Agent tasks have step/time/tool budgets and chat context has a token budget.
6. **Grounding is measurable.** RAG and durable-memory retrieval have deterministic regression gates in addition to unit tests.
7. **No microservices until scale requires them.** V4 remains one Python service with explicit internal boundaries.
8. **Development is version-controlled.** Developer Agent changes happen only in a separate Git checkout/branch, never by rewriting the running Lumi source tree in place.

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
 ├─ TaskRuntime                                         │
 │    ├─ LLMTaskPlanner                                 │
 │    ├─ ToolRegistry                                   │
 │    ├─ PolicyEngine                                   │
 │    ├─ budgets                                        │
 │    └─ approval boundary                              │
 │                                                       │
 └─ DeveloperRuntime                                    │
      ├─ read-only Git repository inspection            │
      ├─ strict DeveloperProposal                       │
      ├─ approval #1: exact plan + diff                 │
      ├─ isolated lumi/dev-* branch                     │
      ├─ fixed allow-listed validation profiles         │
      ├─ approval #2: publish                           │
      └─ commit + push + DRAFT PR, never merge          │
                                                        │
              ModelGateway ← Ollama ────────────────────┘
                      │
                      ▼
          SQLite + FTS/vector/audit state
```

## Domain boundaries

### ChatRuntime
Owns conversational generation, RAG context, durable-memory recall, streaming, and cancellation. Chat does not execute tools implicitly.

### ContextManager
Selects recent dialogue by estimated token budget and compacts older turns into a persisted conversation summary. Summaries are context, not authority. When the model is unavailable, compaction degrades to a deterministic extractive fallback.

### TaskRuntime
Owns task lifecycle: receive → plan → act → observe → finish. It enforces step/time/tool budgets and persists every proposed tool call. It never bypasses PolicyEngine.

### DeveloperRuntime
Owns software-change lifecycle: inspect → propose → user approval → isolated branch → apply exact proposal → run fixed validation profiles → user publish approval → commit/push → draft pull request. It never auto-merges and it refuses to target the running source checkout.

### ModelGateway
Normalizes model providers, timeouts, metadata, fallbacks, and streaming formats. Agent and developer planning fail closed if model output is unavailable or malformed.

### Storage
Owns migrations and durable records. SQLite is the canonical store.

### RAG
Owns ingestion, chunk metadata, sparse+dense retrieval, rank fusion, reranking, citations, and retrieval evaluation.

### Tools
Each tool exposes a typed Pydantic argument schema, risk level, timeout, side-effect flag, and executor. Tool proposals are evaluated before execution and audited after execution.

### Memory
Durable memory is separate from raw conversation history and summaries. A durable item is created only by an explicit user-approved API/UI action. It is searchable through FTS5 and, when available, local embeddings with weighted reciprocal-rank fusion. Items are inspectable, editable, and hard-deletable.

## Security model

External documents, websites, emails, tool output, model-generated tool arguments, repository content, conversation summaries, and retrieved memory are context with explicit trust boundaries; none can override system policy.

Workspace tools resolve every path against a dedicated configured root after symlink resolution. Absolute paths and parent traversal outside that root are rejected. `workspace.write_text` requires explicit approval of displayed arguments. Delete and general shell tools are not registered. Critical tools are disabled by policy.

Durable memory is never inferred and persisted silently in M4. The agent tool registry exposes no autonomous memory-write tool. Chat can only recall records that were deliberately saved by the user.

Developer Agent uses a separate configured Git checkout. Planning is read-only. The first approval authorizes only the exact displayed create/replace operations plus fixed test profiles. The second approval authorizes commit/push/draft-PR publication. Model-supplied shell commands, arbitrary network requests, `.git` writes, deletes, absolute paths, traversal, unexpected worktree changes, and automatic merge are rejected. GitHub credentials remain process-environment secrets and are not persisted or returned by the API.

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

### M5 — Developer Agent — functional alpha implemented
- separate-checkout repository inspection
- strict typed full-file proposal with bounded scope
- exact pre-approval diff
- isolated `lumi/dev-*` branch creation only after approval
- UTF-8 create/replace operations only; no deletes or arbitrary shell
- fixed allow-listed validation profiles selected by changed paths
- durable developer session + event audit trail
- second explicit approval before commit/push/PR
- GitHub-only draft PR publisher with environment-only token
- native macOS review/approval window
- no automatic merge and no direct in-place self-modification

Exit gate: workflow success, denial, dirty-repository guard, path-escape guard, local Git branch/commit/push behavior, Swift transport/build, and existing RAG/memory/security suites must remain green in CI. Real Ollama planning plus a real GitHub draft-PR publish remain machine-specific acceptance tests.
