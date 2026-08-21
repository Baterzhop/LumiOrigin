# Lumi V4 RC2 Release Candidate

This document defines the local release process for the V4 RC2 line.

## Supported target

- macOS 13 or newer for the native client.
- Python 3.11 or newer; CI and release artifacts use Python 3.12.
- Ollama-compatible local chat endpoint is optional for fallback operation but required for real generated answers and Developer Agent planning.
- The default deployment model is one local user on one machine.

## One-command local installation

From the repository root:

```bash
bash scripts/install_lumi.sh
```

On macOS this creates a stable, non-editable Core environment at:

```text
~/Library/Application Support/Lumi/runtime/venv
```

initializes state under `~/Library/Application Support/Lumi/data`, runs the Core doctor, creates an ad-hoc signed `dist/Lumi.app`, and copies the application to `~/Applications/Lumi.app` by default.

Use `--no-user-app` to keep only `dist/Lumi.app`, or `--core-only` to skip the app build.

## Normal macOS startup

After installation:

```bash
open "$HOME/Applications/Lumi.app"
```

The native app now owns the normal local Core lifecycle:

1. read secure connection configuration;
2. check whether Core is already healthy;
3. if the configured URL is local and Core is offline, locate the installed `lumi-core` executable;
4. start it on the configured loopback port;
5. wait for health before constructing the normal chat UI;
6. terminate only the Core child process started by this app when Lumi exits.

The app-managed process writes stdout/stderr to `~/Library/Logs/Lumi/core.log` and uses `~/Library/Application Support/Lumi/data` unless `LUMI_DATA_DIR` is explicitly supplied.

`scripts/start_lumi.sh` is now a convenience launcher on macOS. A terminal is not required to stay open for ordinary use.

## Native connection settings

The Settings window stores the Core URL in UserDefaults and the optional API key in macOS Keychain. Environment variables continue to take precedence for development/automation.

Security rules:

- HTTP URLs are accepted only for loopback hosts;
- remote Core configuration must use HTTPS;
- saved API keys must contain at least 24 characters;
- deleting the saved key removes the generic-password Keychain item.

Restart the app after changing Core connection settings so all view models use the new client configuration.

## Core operations CLI

The standard macOS runtime exposes:

```bash
CORE="$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core"
"$CORE" version
"$CORE" doctor
"$CORE" migrate
"$CORE" backup
"$CORE" restore <backup.sqlite3> --yes
"$CORE" serve
```

`doctor` checks validated configuration, SQLite integrity and local-model availability. Model availability is informational unless `--require-model` is supplied.

## Backup and recovery

Create a verified backup:

```bash
"$CORE" backup --full
```

Restore is deliberately explicit and requires Core to be stopped:

```bash
"$CORE" restore ~/.lumi-backup.sqlite3 --yes --full
```

Before replacing an existing database, restore creates a `pre-restore-*` safety backup. The source backup is verified before use, the restored temporary database is verified before replacement, and the final database is verified again after replacement.

Do not run restore while Lumi Core is active. The restore path attempts an exclusive SQLite lock and fails closed when the database is in use.

## Local acceptance test

After installing, the physical target-Mac gate is:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/acceptance_local.py --require-model
```

The acceptance script exercises liveness/readiness, runtime metadata, ordinary chat, SSE streaming, durable-memory create/search/delete, document upload/retrieval and tool-registry discovery. `--require-model` additionally requires the configured local model to answer without fallback.

## macOS package

Build locally:

```bash
bash scripts/build_macos_app.sh
```

Outputs:

```text
dist/Lumi.app
dist/Lumi-macOS-4.0.0rc2.zip
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
4. Deterministic multilingual RAG regression gate.
5. Deterministic multilingual memory regression gate.
6. Real fallback HTTP + SSE acceptance against a live Core process.
7. Real primary-model + dense-embedding acceptance against the deterministic Ollama-compatible CI server.
8. Python wheel/sdist build and clean-environment wheel smoke.
9. Swift debug build and tests, including secure connection validation.
10. macOS release app bundle build, plist validation and code-sign verification.
11. Production-style macOS installation into the stable Application Support runtime.
12. Live fallback acceptance against that installed runtime.
13. Physical target-Mac acceptance with `scripts/acceptance_local.py --require-model`.

Items 1–12 are automatable in GitHub Actions. Item 13 is deliberately machine-specific because GitHub does not have the user's actual installed Ollama models or target-machine session.
