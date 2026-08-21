# Lumi V4 RC5

Lumi is a local-first AI assistant platform for macOS. V4 is a ground-up redesign with a native SwiftUI client and a Python Core that owns orchestration, durable state, retrieval, memory, policy-gated tools and the Developer Agent.

## Current release-candidate architecture

```text
Lumi.app (SwiftUI)
  ├─ first-run Ollama/model setup
  ├─ secure Core URL + Keychain API-key configuration
  ├─ installed-model discovery
  ├─ local Core lifecycle manager
  ├─ native Readiness Center
  │    └─ runs the packaged installed-runtime acceptance contract
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
  ├─ packaged `lumi-core acceptance` readiness probe
  └─ Ollama-compatible local model gateway
```

## Safety model

- local loopback access by default;
- remote/LAN client configuration rejects plain HTTP and requires HTTPS;
- Core and Ollama server URLs cannot contain embedded credentials, query strings or fragments;
- optional Core API keys are stored by the native client in macOS Keychain;
- acceptance passes API keys to its child process only through the environment, never CLI arguments;
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

## First launch and model setup

On the first successful local launch, Lumi opens **Finish Lumi setup** instead of dropping directly into chat. The setup flow lets the user:

1. configure the Ollama server;
2. query Ollama's typed `GET /api/tags` endpoint;
3. select the installed chat model;
4. select an embedding model or disable dense retrieval;
5. save the settings and restart only the Core process owned by Lumi;
6. intentionally continue in fallback mode when no local model is available yet.

This removes the previous first-use ambiguity where a technically successful installation could silently remain on the deterministic fallback because the configured model was not installed.

## Native settings, models, diagnostics and readiness

Use **Lumi → Settings** to configure the Core URL and an optional API key. Remote Core URLs must use HTTPS. API keys are stored in macOS Keychain rather than UserDefaults.

The same Settings window configures the app-managed local model runtime:

- Ollama server URL;
- chat model;
- embedding model;
- dense-retrieval toggle.

Use **Discover installed models** to query the configured Ollama server and select from models already present. The app does not execute a shell command for discovery. **Save models & restart managed Core** persists the selection and restarts only a Core process owned by Lumi; an external or remote Core is never terminated by this action. Explicit `LUMI_OLLAMA_*` environment variables remain higher-priority development/automation overrides.

Use **Core → Open Readiness Center…** (`⇧⌘R`) for the machine-local release gate. In real-model mode it runs the installed `lumi-core acceptance --require-model` contract and fails if ordinary chat or SSE uses fallback. The probe validates Core health/readiness, runtime metadata, chat, streaming, durable-memory round-trip, grounded knowledge retrieval, tool-registry discovery and a verified database backup. Its temporary memory is removed, while its dedicated conversation and deterministic knowledge probe are reused so repeated checks do not create unbounded state.

Use **Core → Open Diagnostics…** (`⇧⌘I`) to collect a support report containing only non-secret runtime metadata: app/Core versions, Core state, configured URLs, model names, Keychain-presence state, runtime/data/log paths, provider/model names and tool counts. The diagnostics view never includes API-key values, prompts, chat text, memory contents or knowledge-document contents.

## Operations

The installed Core CLI is available at:

```bash
CORE="$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core"
"$CORE" doctor
"$CORE" migrate
"$CORE" backup --full
"$CORE" restore /path/to/backup.sqlite3 --yes --full
"$CORE" acceptance
"$CORE" acceptance --require-model
"$CORE" serve
```

The authoritative physical-Mac real-model command is now self-contained in the installed runtime:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core" acceptance --require-model
```

`scripts/acceptance_local.py` remains only as a repository/development compatibility wrapper around the same packaged contract.

## Knowledge

Lumi ingests text-extractable PDF, Markdown and text files. Retrieval combines SQLite FTS5/BM25 with optional Ollama embeddings through weighted reciprocal-rank fusion and can optionally use a CrossEncoder reranker. Responses carry document/chunk/page citations. OCR for image-only scanned PDFs is outside the defined V4 GA scope rather than an implicit claim of support.

## Memory

Conversation input is token-budgeted. Older dialogue can be compacted into persisted summaries. Durable memory is created only from an explicit approved user action and is retrievable through FTS5 plus optional embeddings. Regression datasets include English, Ukrainian, German and Hungarian plumbing cases.

## Agent tools

Read/list/search tools are sandboxed. `workspace.write_text` requires explicit approval of the exact arguments. Task execution has step, tool-call and wall-clock budgets. Shell, delete and arbitrary HTTP executors are not exposed.

## Developer Agent

Developer mode operates only on a separate clean checkout/worktree. It inspects read-only state, proposes typed UTF-8 create/replace operations, renders an exact diff, waits for approval, applies changes on an isolated `lumi/dev-*` branch and runs only fixed validation profiles. A second approval is required before commit/push/draft-PR publication. Lumi never auto-merges.

## Security and recovery

Hardened configuration rejects weak API keys, wildcard CORS and unsafe network settings. API/GitHub secrets are not represented in settings logs. Every existing SQLite database is backed up before migration by default, backups are verified, `/ready` checks database integrity, and restore performs source/temp/final integrity checks plus a pre-restore safety backup.

## Release artifact integrity and notarization

The release workflow emits SHA-256 checksums next to the Python distributions and macOS ZIP. Verify downloaded artifacts before use:

```bash
# macOS ZIP
shasum -a 256 -c Lumi-macOS-4.0.0rc5.zip.sha256

# Python artifact directory on Linux
sha256sum -c SHA256SUMS
```

For public macOS distribution, the repository also contains a credential-ready notarization path:

```bash
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

The profile must already exist in macOS Keychain via `xcrun notarytool store-credentials`. The script performs Developer-ID build/sign verification, notarization with `--wait`, stapling, stapler validation, Gatekeeper assessment, post-staple repackaging and SHA-256 verification. Repository CI validates this entrypoint syntactically, but cannot claim Apple notarization without real Apple credentials.

## Verification

The automated release gate covers:

- Ubuntu/macOS Python install + dependency checks;
- full unit/API/security/RAG/memory/tools/Developer-Agent/acceptance tests;
- multilingual deterministic RAG/memory regressions;
- fallback HTTP/SSE live acceptance through the packaged Core command;
- primary-model + dense-embedding HTTP/SSE acceptance against an Ollama-compatible deterministic CI server, with fallback forbidden;
- Python wheel/sdist build plus clean-environment wheel install and packaged-acceptance command smoke;
- Swift build/tests, including secure Core/Ollama URL validation, persisted model settings, environment override behavior, model discovery and acceptance-command configuration;
- macOS `.app` packaging, plist validation, code-sign and checksum verification;
- production-style macOS one-command installation into the stable runtime layout;
- live acceptance executed by the **installed** `lumi-core` binary, not a repository-only test script;
- syntax validation of the Developer-ID/notarization entrypoint.

The final physical target-machine gate remains separate because GitHub cannot access the actual installed Ollama models or the user's macOS session. It is run either from the Readiness Center or with:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core" acceptance --require-model
```

GA tracking is explicit in GitHub issue #44. Public distribution additionally requires real Developer-ID/notarization credentials and a successful Gatekeeper check. See `CHANGELOG.md`, `SECURITY.md`, `docs/architecture.md`, `docs/hardening.md`, `docs/release.md`, `docs/reproducibility.md`, `docs/support.md` and `RELEASE_CHECKLIST.md` for design, security and release contracts.
