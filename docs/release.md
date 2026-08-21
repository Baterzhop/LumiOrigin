# Lumi V4 Release Candidate

This document defines the local release process for the V4 release-candidate line.

## Supported target

- macOS 13 or newer for the native client.
- Python 3.11 or newer; CI and release artifacts use Python 3.12.
- Ollama-compatible local chat endpoint is optional for basic operation but required for real generated answers and Developer Agent planning.
- The default deployment model is one local user on one machine.

## One-command local installation

From the repository root:

```bash
bash scripts/install_lumi.sh
```

This creates `.venv`, installs `lumi-core`, initializes/migrates the local SQLite state, runs the Core doctor, and on macOS creates an ad-hoc signed `dist/Lumi.app`.

Start the complete local stack:

```bash
bash scripts/start_lumi.sh
```

The script starts Lumi Core on loopback, waits for `/ready`, opens the macOS application, and keeps Core attached to the terminal so it can be stopped cleanly with Ctrl-C.

## Core operations CLI

Installation exposes:

```bash
lumi-core version
lumi-core doctor
lumi-core migrate
lumi-core backup
lumi-core restore <backup.sqlite3> --yes
lumi-core serve
```

`doctor` checks validated configuration, SQLite integrity and local-model availability. Model availability is informational unless `--require-model` is supplied.

For CI or a machine without Ollama:

```bash
LUMI_RAG_DENSE=false lumi-core doctor --initialize --no-model --require-database
```

## Backup and recovery

Create a verified backup:

```bash
lumi-core backup --full
```

Restore is deliberately explicit and requires Core to be stopped:

```bash
lumi-core restore ~/.lumi-backup.sqlite3 --yes --full
```

Before replacing an existing database, restore creates a `pre-restore-*` safety backup. The source backup is verified before use, the restored temporary database is verified before replacement, and the final database is verified again after replacement.

Do not run restore while Lumi Core is active. The restore path attempts an exclusive SQLite lock and fails closed when the database is in use.

## Local acceptance test

Start Core, preferably against an isolated data directory:

```bash
export LUMI_DATA_DIR="$(mktemp -d)"
export LUMI_RAG_DENSE=false
export LUMI_MODEL_TIMEOUT=2
lumi-core serve
```

In a second terminal:

```bash
python scripts/acceptance_local.py
```

The acceptance script exercises liveness/readiness, runtime metadata, ordinary chat, SSE streaming, durable-memory create/search/delete, document upload/retrieval and tool-registry discovery.

To require a real local model instead of allowing fallback:

```bash
python scripts/acceptance_local.py --require-model
```

The release is not accepted on the target machine until this real-model variant passes.

## macOS package

Build locally:

```bash
bash scripts/build_macos_app.sh
```

Outputs:

```text
dist/Lumi.app
dist/Lumi-macOS-<version>.zip
```

The local build is ad-hoc signed by default. A different signing identity can be selected with:

```bash
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
```

Developer-ID signing and Apple notarization are distribution concerns and are not claimed by the repository until valid Apple credentials are configured.

## GitHub release artifacts

`.github/workflows/v4-release.yml` builds:

- Python wheel + source distribution;
- macOS app ZIP.

The workflow runs manually or for tags matching `v4.*`.

## Release gate

A release-candidate commit is acceptable only if all of the following are green:

1. Python install and `pip check`.
2. `lumi-core doctor` initialization.
3. Full Python unit/API/security/RAG/memory/tool/Developer-Agent tests on Ubuntu and macOS.
4. Deterministic RAG regression gate.
5. Deterministic memory regression gate.
6. Real HTTP + SSE acceptance against a live Core process.
7. Python wheel/sdist build.
8. Swift debug build and tests.
9. macOS release app bundle build, plist validation and code-sign verification.
10. Target-Mac acceptance with `scripts/acceptance_local.py --require-model`.

Items 1–9 are automatable in GitHub Actions. Item 10 is deliberately machine-specific because GitHub does not have the user's local Ollama models, data directory or Keychain/session environment.
