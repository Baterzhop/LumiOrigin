# Lumi V4 — Foundation + M1 + M2 + M3 + M4 + M5

Lumi V4 is a ground-up redesign of Lumi as a local-first AI assistant platform rather than a single chat class. The current branch is a modular monolith: one Python core service, durable SQLite state, grounded RAG, policy-gated tools, token-budget context management, explicit durable memory, an approval-gated Developer Agent, and a native SwiftUI client.

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
  ├─ Developer runtime
  │   ├─ separate Git checkout inspection
  │   ├─ strict typed proposal
  │   ├─ exact diff review
  │   ├─ approval-gated branch/apply/validation
  │   └─ second approval → commit/push/draft PR
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
        ├─ separate developer checkout
        └─ Ollama-compatible local models
```

## What works now

- FastAPI health/runtime/chat/stream/knowledge/task/tool/memory/developer APIs.
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
- Developer Agent inspects a separate clean Git checkout and produces a strict bounded file proposal before any mutation.
- Developer file changes are limited to UTF-8 `create`/`replace`; `.git`, delete, arbitrary shell, arbitrary HTTP, absolute paths, traversal, and symlink escape are rejected.
- The exact proposed diff is shown before approval.
- Local developer validation uses fixed allow-listed profiles only and is disabled by default because tests execute repository code.
- If required checks are disabled, skipped, or fail, the developer session cannot be published.
- Commit/push/draft-PR publication requires a second explicit approval, and Lumi never auto-merges.
- Developer workflow state, diff, validation, branch, commit, PR URL, and events are persisted for audit; GitHub credentials are not.
- Tool outputs, repository content, retrieved documents, summaries, and recalled memory have explicit trust boundaries.
- Deterministic RAG and memory retrieval regression gates run in CI.
- Python unit/API/security/developer tests on Linux/macOS plus Swift build/tests in CI.

## Alpha install

The H2 release-engineering path installs Lumi Core with the committed Python 3.12 direct-dependency constraints and runs storage diagnostics:

```bash
./scripts/install_lumi.sh
./scripts/start_lumi.sh
```

Operational commands are exposed through the installed `lumi-core` CLI:

```bash
.lumi-runtime/venv/bin/lumi-core doctor --strict
.lumi-runtime/venv/bin/lumi-core backup --full-check
# Stop Core before restoring:
.lumi-runtime/venv/bin/lumi-core restore /path/to/backup.sqlite3 --yes
```

The native macOS client has a standard **Settings** window for the Core base URL and API key. API keys are stored in macOS Keychain. Changing connection settings requires an app restart so all windows use one consistent client instance.

Build the controlled alpha `.app` package:

```bash
./scripts/build_macos_app.sh
```

This produces `dist/Lumi.app` and `dist/Lumi-macOS-alpha.zip`. Alpha packages are ad-hoc signed for local testing; they are not Developer-ID signed or notarized.

Run the deterministic process-level Core acceptance test:

```bash
python scripts/acceptance_local.py
```

See `docs/release.md` and `RELEASE_CHECKLIST.md` before creating an alpha tag.

## Manual development run

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

Developer Agent is disabled until a **separate Git checkout/worktree** is configured:

```bash
export LUMI_DEV_REPO_ROOT="$HOME/Projects/Lumi-dev-worktree"
export LUMI_DEV_BASE_BRANCH=main
```

Local developer validation is intentionally disabled by default. Enable it only when you are willing to execute the repository's fixed validation profiles after reviewing the proposed code change:

```bash
export LUMI_DEV_ALLOW_LOCAL_CHECKS=true
```

When required checks cannot run, Lumi uses `validation_incomplete` and blocks publish rather than treating skipped validation as success.

Optional GitHub draft-PR publishing:

```bash
export LUMI_DEV_GITHUB_REPOSITORY="owner/repository"
export LUMI_DEV_GITHUB_TOKEN="..."
```

The GitHub token is read from the environment only; Lumi does not persist or return it. The Developer Agent refuses to target the running Lumi source checkout and never auto-merges a PR.

The autonomous task and developer planners require a working chat model. If Ollama is unavailable, ordinary chat can fall back, but planning fails closed rather than inventing tool calls or code changes.

To enable the optional CrossEncoder reranker:

```bash
python -m pip install -e "services/core[rerank]"
export LUMI_RERANKER_MODEL=<cross-encoder-model>
```

## Run macOS client from source

```bash
cd apps/macos
swift run LumiDesktop
```

Or open `apps/macos/Package.swift` in Xcode. The Developer Agent review window is available from the **Developer** menu (`⇧⌘D`).

## Test

```bash
pytest services/core/tests
python scripts/eval_rag.py --assert-thresholds
python scripts/eval_memory.py --assert-thresholds
cd apps/macos && swift test
```

See `docs/architecture.md`, `docs/event-protocol.md`, `docs/rag.md`, `docs/tools.md`, `docs/memory.md`, `docs/developer-agent.md`, `docs/hardening.md`, and `docs/release.md` for design contracts and current limitations.
