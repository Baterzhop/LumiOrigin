# Changelog

All notable Lumi V4 release-candidate changes are recorded here.

## 4.0.0rc5 — 2026-08-21

Target-machine readiness and first-run completion:

- added a packaged `lumi-core acceptance` command so the installed runtime can execute its own release contract without repository-script dependencies;
- made acceptance repeatable with one dedicated conversation and deterministic deduplicated knowledge probe while cleaning temporary durable memory;
- expanded live acceptance to cover health/readiness, ordinary chat, SSE, real-model fallback enforcement, durable-memory retrieval, grounded knowledge retrieval, tool-registry discovery and verified database backup;
- added a native **Lumi Readiness Center** that runs the installed acceptance command and shows provider/model/fallback/SSE status;
- added first-run Ollama/model setup with installed-model discovery, chat/embedding selection, dense-retrieval control and safe managed-Core restart;
- kept Core API keys out of command-line arguments and passed them to the acceptance child only through its process environment;
- added Python and Swift regression tests for the packaged acceptance contract;
- added a credential-ready Developer-ID/notarization/stapling/Gatekeeper script and CI syntax validation;
- moved CI and installed-runtime smoke from repository-only acceptance scripts to the packaged `lumi-core acceptance` command;
- bumped Core and macOS artifacts to `4.0.0rc5`.

## 4.0.0rc4 — 2026-08-21

First-use local model configuration:

- added native Ollama server, chat-model, embedding-model and dense-retrieval settings for the app-managed Core;
- added installed-model discovery through Ollama's fixed `GET /api/tags` endpoint;
- persisted non-secret model settings in UserDefaults while keeping Core API keys in Keychain;
- injected saved model configuration only into Core processes owned by Lumi, while preserving explicit environment-variable overrides;
- added managed-Core restart after model changes without terminating external/remote Core processes;
- extended diagnostics with configured non-secret model metadata;
- added Swift validation, persistence, environment-mapping and model-discovery transport tests.

## 4.0.0rc3 — 2026-08-21

Release polish and supportability:

- hardened native Core URL validation against embedded credentials, query strings and fragments;
- added a metadata-only native diagnostics window with copy/open-log/open-data actions;
- added SHA-256 checksum generation to Python and macOS release artifacts;
- added explicit GA tracking for the physical target-Mac/Ollama and Apple notarization gates;
- clarified release, support and security documentation.

## 4.0.0rc2 — 2026-08-21

Native desktop runtime integration:

- Lumi.app can start and stop its own installed local Core runtime;
- stable Core runtime under `~/Library/Application Support/Lumi/runtime/venv`;
- app data under `~/Library/Application Support/Lumi/data`;
- Core log under `~/Library/Logs/Lumi/core.log`;
- native startup/recovery UI;
- secure Core URL configuration and API-key storage in macOS Keychain;
- remote plain HTTP rejected;
- one-command production-style macOS installation and CI acceptance.

## 4.0.0rc1 — 2026-08-21

Ground-up Lumi V4 foundation:

- FastAPI Core with SQLite canonical state and migrations;
- native SwiftUI macOS client;
- HTTP/SSE chat streaming and cancellation;
- grounded PDF/Markdown/TXT RAG with FTS5, optional embeddings, weighted RRF and citations;
- explicit durable memory and token-budget context management;
- policy-gated agent tools with exact-argument approval for side effects;
- bounded Agent Runtime;
- approval-gated Developer Agent using isolated branches and draft PRs only;
- backup/restore, health/readiness, loopback-first networking and API-key remote boundary;
- multilingual deterministic RAG/memory regressions;
- Python/macOS packaging and release CI.

## GA policy

`4.0.0` GA is not declared until the real-model physical target-Mac acceptance gate is completed. Public macOS distribution additionally requires Apple Developer-ID signing and notarization. See GitHub issue #44 and `RELEASE_CHECKLIST.md`.
