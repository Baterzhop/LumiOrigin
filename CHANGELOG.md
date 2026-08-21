# Changelog

All notable Lumi V4 release-candidate changes are recorded here.

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
