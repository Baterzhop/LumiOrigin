# Lumi V4 RC3

Lumi is a local-first AI assistant platform for macOS. V4 is a ground-up redesign with a native SwiftUI client and a Python Core that owns orchestration, durable state, retrieval, memory, policy-gated tools and the Developer Agent.

## Current release-candidate architecture

```text
Lumi.app (SwiftUI)
  ├─ secure Core URL + Keychain API-key configuration
  ├─ local Core lifecycle manager
  │    └─ starts/stops installed local lumi-core when needed
  │
  │ HTTP / SSE / approvals / uploads
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
- remote/LAN client configuration rejects plain HTTP and requires HTTPS;
- Core URLs cannot contain embedded credentials, query strings or fragments;
- optional Core API keys are stored by the native client in macOS Keychain;
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
bash scripts/install_lumi.sh
open "$HOME/Applications/Lumi.app"
```

The installer creates a stable Core runtime at:

```text
~/Library/Application Support/Lumi/runtime/venv
```

and local state at:

```text
~/Library/Application Support/Lumi/data
```

It builds an ad-hoc signed macOS application and installs it to `~/Applications/Lumi.app` by default. Opening Lumi checks for an existing Core and, for the default local configuration, starts the installed Core automatically. A terminal does not have to remain open for normal macOS use.

Core logs from the app-managed process are written to:

```text
~/Library/Logs/Lumi/core.log
```

## Native settings and diagnostics

Use **Lumi → Settings** to configure the Core URL and an optional API key. Remote Core URLs must use HTTPS. API keys are stored in macOS Keychain rather than UserDefaults. Restart Lumi after changing connection settings.

Use **Core → Open Diagnostics…** (`⇧⌘I`) to collect a support report containing only non-secret runtime metadata: app/Core versions, Core state, configured URL, Keychain-presence state, runtime/data/log paths, provider/model names and tool counts. The diagnostics view never includes API-key values, prompts, chat text, memory contents or knowledge-document contents.

## Operations

The installed Core CLI is available at:

```bash
CORE="$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core"
"$CORE" doctor
"$CORE" migrate
"$CORE" backup --full
"$CORE" restore /path/to/backup.sqlite3 --yes --full
"$CORE" serve
```

For a real local-model acceptance test from the repository:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/acceptance_local.py --require-model
```

## Knowledge

Lumi currently ingests PDF, Markdown and text files. Retrieval combines SQLite FTS5/BM25 with optional Ollama embeddings through weighted reciprocal-rank fusion and can optionally use a CrossEncoder reranker. Responses carry document/chunk/page citations. Scanned-PDF OCR remains outside RC3.

## Memory

Conversation input is token-budgeted. Older dialogue can be compacted into persisted summaries. Durable memory is created only from an explicit approved user action and is retrievable through FTS5 plus optional embeddings. Regression datasets include English, Ukrainian, German and Hungarian plumbing cases.

## Agent tools

Read/list/search tools are sandboxed. `workspace.write_text` requires explicit approval of the exact arguments. Task execution has step, tool-call and wall-clock budgets. Shell, delete and arbitrary HTTP executors are not exposed.

## Developer Agent

Developer mode operates only on a separate clean checkout/worktree. It inspects read-only state, proposes typed UTF-8 create/replace operations, renders an exact diff, waits for approval, applies changes on an isolated `lumi/dev-*` branch and runs only fixed validation profiles. A second approval is required before commit/push/draft-PR publication. Lumi never auto-merges.

## Security and recovery

Hardened configuration rejects weak API keys, wildcard CORS and unsafe network settings. API/GitHub secrets are not represented in settings logs. Every existing SQLite database is backed up before migration by default, backups are verified, `/ready` checks database integrity, and restore performs source/temp/final integrity checks plus a pre-restore safety backup.

## Release artifact integrity

The release workflow emits SHA-256 checksums next to the Python distributions and macOS ZIP. Verify downloaded artifacts before use:

```bash
# macOS ZIP
shasum -a 256 -c Lumi-macOS-4.0.0rc3.zip.sha256

# Python artifact directory on Linux
sha256sum -c SHA256SUMS
```

Checksums prove transfer integrity; they do not replace Apple Developer-ID signing/notarization for public macOS distribution.

## Verification

The release gate covers:

- Ubuntu/macOS Python install + dependency checks;
- exact tested dependency constraints for Lumi's release environment;
- full unit/API/security/RAG/memory/tools/Developer-Agent tests;
- multilingual deterministic RAG/memory regressions;
- fallback HTTP/SSE live acceptance;
- primary-model + dense-embedding HTTP/SSE acceptance against an Ollama-compatible deterministic CI server;
- Python wheel/sdist build plus clean-environment wheel install smoke;
- Swift build/tests, including secure native connection validation;
- macOS `.app` packaging, plist validation and code-sign verification;
- production-style macOS one-command installation into the stable runtime layout;
- live acceptance against that installed Core runtime.

The final physical target-machine model gate remains separate because GitHub cannot access the user's installed Ollama models:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/acceptance_local.py --require-model
```

GA tracking is explicit in GitHub issue #44. See `CHANGELOG.md`, `SECURITY.md`, `docs/architecture.md`, `docs/hardening.md`, `docs/release.md`, `docs/reproducibility.md`, `docs/support.md` and `RELEASE_CHECKLIST.md` for design, security and release contracts.
