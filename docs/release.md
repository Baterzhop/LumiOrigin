# Lumi V4 RC5 Release Candidate

This document defines the local release process for the V4 RC5 line.

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

On macOS this creates a stable Core environment at:

```text
~/Library/Application Support/Lumi/runtime/venv
```

initializes state under `~/Library/Application Support/Lumi/data`, runs the Core doctor, creates an ad-hoc signed `dist/Lumi.app`, and copies the application to `~/Applications/Lumi.app` by default.

Use `--no-user-app` to keep only `dist/Lumi.app`, or `--core-only` to skip the app build.

## Normal macOS startup and first-run setup

After installation:

```bash
open "$HOME/Applications/Lumi.app"
```

The native app owns the normal local Core lifecycle:

1. read secure connection configuration;
2. check whether Core is already healthy;
3. if the configured URL is auto-manageable loopback HTTP and Core is offline, locate the installed `lumi-core` executable;
4. load saved non-secret local model settings unless explicit environment overrides exist;
5. start Core on the configured loopback port;
6. wait for health;
7. on first successful launch, show **Finish Lumi setup** so the user can discover/select the real Ollama chat model and embedding configuration;
8. terminate only the Core child process started by this app when Lumi exits.

The app-managed process writes stdout/stderr to `~/Library/Logs/Lumi/core.log` and uses `~/Library/Application Support/Lumi/data` unless `LUMI_DATA_DIR` is explicitly supplied.

`scripts/start_lumi.sh` is a convenience launcher on macOS. A terminal is not required to stay open for ordinary use.

## Native connection and model settings

The Settings window stores the Core URL in UserDefaults and the optional API key in macOS Keychain. Environment variables continue to take precedence for development/automation.

Security rules:

- HTTP URLs are accepted only for loopback hosts;
- remote Core/model-server configuration must use HTTPS;
- usernames/passwords/API credentials embedded in URLs are rejected;
- query strings and fragments are rejected from base URLs;
- saved API keys must contain at least 24 characters;
- deleting the saved key removes the generic-password Keychain item.

The app-managed Ollama configuration includes:

- Ollama server URL;
- chat model name;
- embedding model name;
- dense-retrieval enable/disable toggle.

**Discover installed models** calls Ollama `GET /api/tags` using typed HTTP transport. It does not execute a shell command. **Save models & restart managed Core** persists the non-secret configuration and restarts only a Core child process owned by Lumi. External/remote Core processes are never terminated by this action.

Saved values map to:

```text
LUMI_OLLAMA_URL=<server>/api/chat
LUMI_OLLAMA_EMBED_URL=<server>/api/embed
LUMI_OLLAMA_MODEL=<chat model>
LUMI_EMBEDDING_MODEL=<embedding model>
LUMI_RAG_DENSE=true|false
```

Explicit process environment values remain higher-priority overrides.

## Native diagnostics and Readiness Center

Use **Core → Open Diagnostics…** (`⇧⌘I`) for metadata-only troubleshooting. It excludes API-key values, prompts/chat text, durable-memory contents, knowledge-document contents and repository contents.

Use **Core → Open Readiness Center…** (`⇧⌘R`) for target-machine acceptance. The Readiness Center runs the packaged installed-runtime acceptance command. In real-model mode the check fails if either ordinary chat or streaming falls back.

## Core operations CLI

The standard macOS runtime exposes:

```bash
CORE="$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core"
"$CORE" version
"$CORE" doctor
"$CORE" migrate
"$CORE" backup
"$CORE" restore <backup.sqlite3> --yes
"$CORE" acceptance
"$CORE" acceptance --require-model
"$CORE" serve
```

`doctor` checks validated configuration, SQLite integrity and local-model availability. Model availability is informational unless `--require-model` is supplied.

`acceptance` is a packaged, installed-runtime contract. It validates:

- liveness and readiness;
- runtime metadata;
- ordinary chat;
- SSE streaming;
- `fallback:false` when `--require-model` is requested;
- durable-memory create/search/delete round trip;
- grounded knowledge upload/query;
- non-empty tool registry;
- verified database backup creation.

The probe is repeatable: it reuses a dedicated acceptance conversation and deterministic knowledge document instead of creating unbounded rows, and deletes its temporary durable-memory record after each run.

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

## Physical target-Mac acceptance

After installation and selecting an actually installed Ollama chat model, run either the native Readiness Center in **Require real model** mode or:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core" acceptance --require-model
```

The result must return `"ok": true` and `"fallback": false`. This command is part of the installed wheel/runtime, so it does not depend on keeping a repository checkout or invoking a repository-only Python file.

The external GA checklist is tracked in GitHub issue #44. Repository CI cannot substitute for the actual target-machine Ollama/macOS session.

## macOS package

Build the local/ad-hoc package:

```bash
bash scripts/build_macos_app.sh
```

Outputs:

```text
dist/Lumi.app
dist/Lumi-macOS-4.0.0rc5.zip
```

## Developer-ID signing and notarization

The repository is credential-ready for public distribution:

```bash
xcrun notarytool store-credentials "lumi-notary" ...
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

The notarization script:

1. refuses ad-hoc/no signing identities;
2. builds with the selected Developer ID Application identity;
3. verifies codesign;
4. submits the ZIP with `xcrun notarytool ... --wait` using a Keychain profile;
5. staples and validates the ticket on `Lumi.app`;
6. runs Gatekeeper `spctl --assess`;
7. recreates the distribution ZIP after stapling;
8. creates and verifies the final SHA-256 file.

Real Apple credentials are external secrets, so repository CI validates the entrypoint but does not claim notarization has passed until it has actually run with valid credentials.

## GitHub release artifacts and checksums

`.github/workflows/v4-release.yml` builds:

- Python wheel + source distribution + `SHA256SUMS`;
- macOS app ZIP + matching `.sha256` file.

Example verification:

```bash
shasum -a 256 -c Lumi-macOS-4.0.0rc5.zip.sha256
sha256sum -c SHA256SUMS
```

## Release gate

A release-candidate commit is repository-ready only if all automatable gates are green on that exact head:

1. Python install and `pip check`.
2. `lumi-core doctor` initialization.
3. Full Python unit/API/security/RAG/memory/tool/Developer-Agent/acceptance tests on Ubuntu and macOS.
4. Deterministic multilingual RAG regression gate.
5. Deterministic multilingual memory regression gate.
6. Live fallback HTTP/SSE acceptance through the packaged `lumi-core acceptance` command.
7. Live primary-model + dense-embedding acceptance with `--require-model` against the deterministic Ollama-compatible CI server.
8. Python wheel/sdist build and clean-environment wheel smoke, including presence of the packaged acceptance command.
9. Swift debug build/tests, including secure Core/model-server configuration, model discovery and acceptance-command configuration.
10. macOS release bundle build, plist validation, code-sign and SHA-256 verification.
11. production-style macOS installation into the stable Application Support runtime.
12. live fallback acceptance invoked by the **installed** `lumi-core` executable.
13. release-artifact checksum generation and verification.
14. shell validation of the credential-ready notarization path.

External gates that cannot be truthfully completed by GitHub-hosted CI:

15. physical target-Mac acceptance with `lumi-core acceptance --require-model` against the actual selected Ollama model;
16. public distribution: real Developer-ID signing, Apple notarization/stapling and Gatekeeper verification on a clean target.
