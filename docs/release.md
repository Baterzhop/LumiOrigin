# Lumi V4 Alpha Release Engineering

H2 turns the hardened M0–M5 build into a repeatable local alpha install. It does **not** claim production distribution readiness.

## Supported alpha target

- macOS 13+
- CPython 3.11+; CI release constraints target Python 3.12
- local Ollama-compatible model service
- one local user

## Deterministic direct dependency set

`requirements/constraints-py312.txt` pins Lumi Core's direct runtime/dev dependencies. Transitive dependencies remain resolver-managed; CI installs the project through the constraints file on Ubuntu and macOS before every test run.

Install locally:

```bash
./scripts/install_lumi.sh
```

This creates `.lumi-runtime/venv`, installs Lumi Core using the committed constraints and runs:

```bash
lumi-core doctor --initialize --skip-model
```

## Start and diagnose

```bash
./scripts/start_lumi.sh
```

The start script binds to `127.0.0.1:8790` by default. A non-loopback bind is refused unless `LUMI_API_KEY` is configured.

Operational diagnostics:

```bash
.lumi-runtime/venv/bin/lumi-core doctor
.lumi-runtime/venv/bin/lumi-core doctor --strict
.lumi-runtime/venv/bin/lumi-core doctor --full-check --json
```

`--strict` treats an unavailable Ollama service as a failure. Storage/configuration failures are always failures.

## Backup and restore

Create a verified backup:

```bash
.lumi-runtime/venv/bin/lumi-core backup --full-check
```

Restore is deliberately explicit and destructive:

```bash
# Stop Lumi Core first.
.lumi-runtime/venv/bin/lumi-core restore /path/to/lumi-backup.sqlite3 --yes
```

The restore flow:

1. runs a full integrity check on the selected backup;
2. creates a pre-restore backup of the current live database;
3. restores into a temporary SQLite file;
4. removes stale WAL/SHM sidecars;
5. atomically replaces the live database;
6. runs a full integrity check on the restored database.

Do not restore while Lumi Core is running. Alpha restore intentionally requires an operator-controlled maintenance window.

## macOS connection settings

The native client now supports the standard macOS **Settings** window.

- Core base URL is stored in `UserDefaults`.
- The API key is stored as a generic password in macOS Keychain.
- Environment `LUMI_API_KEY` still takes precedence for development/test runs.
- Changing connection settings requires restarting Lumi so all existing view models use one consistent client configuration.

The settings layer rejects URL paths, embedded credentials, non-HTTP schemes and API keys shorter than the Core's minimum.

## Build the alpha app

```bash
./scripts/build_macos_app.sh
```

Outputs:

- `dist/Lumi.app`
- `dist/Lumi-macOS-alpha.zip`

The alpha app is **ad-hoc signed**. It is not Developer-ID signed or notarized. Public distribution requires a separate signing/notarization pipeline and Apple developer credentials; those credentials must never be committed to the repository.

## Local deterministic acceptance

```bash
python scripts/acceptance_local.py
```

The acceptance harness starts a deterministic mock Ollama service and a real Uvicorn Lumi Core process on loopback ports, waits for `/ready`, sends a real `/v1/chat` request and fails if Lumi falls back instead of using the configured provider.

This validates the process/network/model-gateway path without pretending to test the user's physical Ollama installation.

## CI/release gates

Pull requests run:

- pinned direct-dependency install on Ubuntu/macOS;
- full Python suite;
- operational CLI smoke;
- RAG regression gate;
- memory regression gate;
- deterministic process-level Core acceptance;
- Swift build/tests;
- macOS `.app` construction and `codesign --verify`.

`v4.*` tags or manual release-workflow dispatch additionally create GitHub Actions artifacts for the macOS alpha app and Core source/install bundle.

## Still required before beta

- real target-Mac Ollama acceptance with the intended chat/embedding models;
- representative Ukrainian/English/German long-horizon evaluations;
- Developer ID signing and notarization for distributable macOS builds;
- upgrade/rollback exercises using copies of real Lumi data;
- crash/restart soak testing;
- performance profiling with a realistically sized document/memory corpus;
- privacy/security review of logs, Keychain behavior, permissions and imported content.
