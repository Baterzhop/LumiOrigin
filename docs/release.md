# Lumi V4 Release and GA Promotion

This document defines the supported installation, verification and final `4.0.0` promotion flow.

## Supported target

- macOS 13 or newer for the native client.
- Python 3.11 or newer; CI/release verification uses Python 3.12.
- Ollama-compatible model endpoint. Fallback mode is supported, but real-model GA acceptance requires an actually available model.
- Default deployment: one local user on one machine.

## Install

From the repository root:

```bash
bash scripts/install_lumi.sh
```

The installer creates:

```text
~/Library/Application Support/Lumi/runtime/venv
~/Library/Application Support/Lumi/data
~/Applications/Lumi.app
```

The native app owns the normal local Core lifecycle. Ordinary use does not require a Terminal window to remain open.

## Normal startup

```bash
open "$HOME/Applications/Lumi.app"
```

On startup Lumi:

1. loads validated Core/model configuration;
2. checks Core readiness;
3. auto-starts only a loopback HTTP Core it is allowed to manage;
4. passes saved non-secret model settings to the managed Core unless explicit environment overrides exist;
5. waits for readiness;
6. shows first-run model setup when required;
7. terminates only the Core child process it started when Lumi exits.

Core logs:

```text
~/Library/Logs/Lumi/core.log
```

## Model and connection security

The native settings layer enforces:

- HTTP only for loopback hosts;
- HTTPS for remote Core/model servers;
- no embedded URL credentials;
- no query/fragment components in base URLs;
- API keys stored in macOS Keychain;
- explicit process environment values override saved settings.

Managed model settings map to:

```text
LUMI_OLLAMA_URL=<server>/api/chat
LUMI_OLLAMA_EMBED_URL=<server>/api/embed
LUMI_OLLAMA_MODEL=<chat model>
LUMI_EMBEDDING_MODEL=<embedding model>
LUMI_RAG_DENSE=true|false
```

## Core operations

```bash
CORE="$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core"
"$CORE" version
"$CORE" doctor
"$CORE" migrate
"$CORE" backup --full
"$CORE" restore <backup.sqlite3> --yes --full
"$CORE" acceptance
"$CORE" acceptance --require-model
"$CORE" serve
```

`acceptance` verifies liveness/readiness, chat + SSE, durable-memory round trip, grounded knowledge, tool registry and backup creation. `--require-model` additionally fails if normal chat or streaming falls back.

## Backup and recovery

Create a verified backup:

```bash
"$CORE" backup --full
```

Restore requires explicit confirmation and Core downtime:

```bash
"$CORE" restore ~/.lumi-backup.sqlite3 --yes --full
```

Restore verifies the source, creates a safety backup of an existing database, restores through a temporary database, verifies it and only then replaces the target.

## Repository CI contract

A release candidate must pass all five V4 jobs:

```text
core (ubuntu-latest, 3.12)
core (macos-14, 3.12)
macos-client
macos-install-smoke
macos-ga-orchestration-smoke
```

Together these cover:

- dependency integrity and Core doctor;
- Python unit/API/security/RAG/memory/tool/Developer-Agent tests;
- deterministic multilingual RAG/memory eval gates;
- fallback HTTP/SSE acceptance;
- primary-model + dense-embedding acceptance;
- wheel/sdist build and clean install verification;
- Swift build/tests and connection/model validation;
- macOS packaging, plist and codesign verification;
- production-style installation;
- installed Core acceptance;
- full hosted macOS GA orchestration.

The hosted GA orchestration launches the installed `Lumi.app`, exercises its managed Core, validates a primary-model grounded citation, restart-persistent memory, read tool, exact approval-gated write and backup/restore-copy. It proves the release orchestration itself but does not replace the real physical target-Mac gate.

## Physical target-Mac GA acceptance

Use the exact commit you intend to promote. Install that candidate, select the real local chat and embedding models, then run:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/ga_acceptance_macos.py
```

Evidence is written to:

```text
~/Library/Application Support/Lumi/ga-evidence/4.0.0-ga.json
```

The probe requires:

- app-managed Core startup;
- installed `lumi-core acceptance --require-model` with `fallback=false`;
- a real-model grounded answer with matching citation metadata;
- durable memory across full app/Core restart;
- read-only tool execution;
- exact persisted write proposal blocked until approval and executed only after approval;
- verified backup and full restore into a disposable copy;
- app-owned Core shutdown ownership.

If runtime code changes after this `candidate_commit`, the target evidence is invalid and must be regenerated.

## Repository governance

`main` must be protected before GA. With an administrator-authenticated GitHub CLI session:

```bash
TARGET="$HOME/Library/Application Support/Lumi/ga-evidence/4.0.0-ga.json"
bash scripts/configure_branch_protection.sh \
  --repository Baterzhop/LumiOrigin \
  --branch main \
  --evidence "$TARGET" \
  --apply
```

The configurator is dry-run by default. With `--apply` it writes GitHub protection, reads the policy back and updates GA governance evidence only after verification succeeds.

The required policy includes pull-request flow, strict status checks for all five V4 jobs, blocked force pushes/deletion and conversation resolution.

## Promote the accepted candidate to 4.0.0

After physical acceptance, only release metadata may differ from the accepted candidate. Set both canonical Core version locations to `4.0.0` through a normal PR and run the five-gate CI again.

The final release verifier allow-list is intentionally narrow:

```text
services/core/pyproject.toml
services/core/src/lumi_core/__init__.py
CHANGELOG.md
README.md
RELEASE_CHECKLIST.md
docs/release.md
release-evidence/4.0.0-ga.json
```

Any other changed file after `candidate_commit` blocks the final tag and requires new physical acceptance.

## Public distribution: Developer ID + Apple notarization

Public downloadable distribution is an additional external gate. After the promotion branch is versioned `4.0.0`:

```bash
xcrun notarytool store-credentials "lumi-notary" ...
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

The script:

1. refuses ad-hoc/no signing identities;
2. builds with the selected Developer ID Application identity;
3. verifies codesign;
4. submits the ZIP using the Keychain notary profile;
5. waits for Apple acceptance;
6. staples and validates the ticket;
7. runs Gatekeeper assessment;
8. recreates the ZIP after stapling;
9. verifies its SHA-256;
10. emits non-secret notarization evidence.

Evidence:

```text
dist/Lumi-macOS-4.0.0.notarization.json
```

## Compose final evidence

No manual JSON editing is required.

Local/non-public GA:

```bash
python3 scripts/compose_ga_evidence.py "$TARGET" \
  --output release-evidence/4.0.0-ga.json
```

Public GA:

```bash
python3 scripts/compose_ga_evidence.py "$TARGET" \
  --notarization dist/Lumi-macOS-4.0.0.notarization.json \
  --public \
  --output release-evidence/4.0.0-ga.json
```

Validate the evidence and promotion:

```bash
python3 scripts/validate_ga_evidence.py release-evidence/4.0.0-ga.json
python3 scripts/verify_ga_promotion.py release-evidence/4.0.0-ga.json --release-ref HEAD
```

For public distribution:

```bash
python3 scripts/validate_ga_evidence.py release-evidence/4.0.0-ga.json --public
```

## Final tag

Only after the physical, governance and applicable Apple gates are real may the final tag be created:

```text
v4.0.0
```

`.github/workflows/v4-release.yml` independently verifies:

- tag/version consistency;
- final GA evidence;
- existence and ancestry of `candidate_commit`;
- target app/Core version matching the accepted candidate;
- final project/runtime version exactly `4.0.0`;
- no runtime or unapproved file changes after physical acceptance.

The workflow fetches full Git history specifically so the promotion proof cannot be bypassed by a shallow checkout.

## GA rule

Green hosted CI is necessary but not sufficient. Lumi V4 is `4.0.0` GA only when physical target-Mac evidence and repository governance are real. Public distribution additionally requires real Developer-ID/notarization/Gatekeeper evidence.
