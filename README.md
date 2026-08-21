# Lumi V4 RC1

Lumi is a local-first AI assistant platform for macOS. V4 is a ground-up redesign with a native SwiftUI client and a Python Core that owns orchestration, durable state, retrieval, memory, policy-gated tools and the Developer Agent.

## Current release-candidate architecture

```text
SwiftUI macOS client
        │  HTTP / SSE / approvals / uploads
        ▼
Lumi Core (FastAPI)
  ├─ streaming chat + cancellation
  ├─ token-budget context manager
  ├─ grounded RAG: FTS5 + optional embeddings + RRF + citations
  ├─ explicit durable memory + multilingual retrieval
  ├─ bounded agent runtime + ToolRegistry + PolicyEngine
  ├─ approval-gated Developer Agent
  ├─ SQLite canonical state + migrations + backup/recovery
  └─ Ollama-compatible local model gateway
```

## Safety model

- local loopback access by default;
- remote/LAN access requires an explicit strong API key;
- untrusted documents, tool output and repository content are never treated as system instructions;
- write tools require approval;
- Developer Agent uses a separate checkout, two explicit approval stages and draft PRs only;
- no runtime self-modification, unrestricted shell, delete tool, arbitrary network executor or automatic merge;
- durable memory is explicit, inspectable, editable and deletable.

## Install on macOS

Requirements: macOS 13+, Python 3.11+ and Swift 5.9+. Ollama is optional for fallback operation and required for real generated answers.

```bash
git clone https://github.com/Baterzhop/LumiOrigin.git
cd LumiOrigin
git checkout lumi-v4-release
bash scripts/install_lumi.sh
bash scripts/start_lumi.sh
```

The installer creates `.venv`, installs the Core, initializes the verified SQLite state and builds an ad-hoc signed `dist/Lumi.app`.

## Operations

```bash
source .venv/bin/activate
lumi-core doctor
lumi-core migrate
lumi-core backup --full
lumi-core restore /path/to/backup.sqlite3 --yes --full
lumi-core serve
```

For a real local-model acceptance test:

```bash
python scripts/acceptance_local.py --require-model
```

## Knowledge

Lumi currently ingests PDF, Markdown and text files. Retrieval combines SQLite FTS5/BM25 with optional Ollama embeddings through weighted reciprocal-rank fusion and can optionally use a CrossEncoder reranker. Responses carry document/chunk/page citations. Scanned-PDF OCR remains outside RC1.

## Memory

Conversation input is token-budgeted. Older dialogue can be compacted into persisted summaries. Durable memory is created only from an explicit approved user action and is retrievable through FTS5 plus optional embeddings. Regression datasets now include English, Ukrainian, German and Hungarian plumbing cases.

## Agent tools

Read/list/search tools are sandboxed. `workspace.write_text` requires explicit approval of the exact arguments. Task execution has step, tool-call and wall-clock budgets. Shell, delete and arbitrary HTTP executors are not exposed.

## Developer Agent

Developer mode operates only on a separate clean checkout/worktree. It inspects read-only state, proposes typed UTF-8 create/replace operations, renders an exact diff, waits for approval, applies changes on an isolated `lumi/dev-*` branch and runs only fixed validation profiles. A second approval is required before commit/push/draft-PR publication. Lumi never auto-merges.

## Security and recovery

Hardened configuration rejects weak API keys, wildcard CORS and unsafe network settings. API/GitHub secrets are not represented in settings logs. Every existing SQLite database is backed up before migration by default, backups are verified, `/ready` checks database integrity, and restore performs source/temp/final integrity checks plus a pre-restore safety backup.

## Verification

The release gate covers:

- Ubuntu/macOS Python install + dependency checks;
- full unit/API/security/RAG/memory/tools/Developer-Agent tests;
- multilingual deterministic RAG/memory regressions;
- fallback HTTP/SSE live acceptance;
- primary-model + dense-embedding HTTP/SSE acceptance against an Ollama-compatible deterministic CI server;
- Python wheel/sdist build;
- Swift build/tests;
- macOS `.app` packaging, plist validation and code-sign verification.

The final target-machine gate is intentionally separate because GitHub cannot access the user's installed Ollama models:

```bash
python scripts/acceptance_local.py --require-model
```

See `docs/architecture.md`, `docs/hardening.md`, `docs/release.md` and `RELEASE_CHECKLIST.md` for design, security and release contracts.
