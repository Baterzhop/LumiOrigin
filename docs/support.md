# Lumi V4 Support Guide

## First response checklist

When Lumi does not start or behaves unexpectedly:

1. open **Core → Open Diagnostics…** in Lumi and refresh the report;
2. run the installed Core doctor;
3. inspect the Core log;
4. use **Lumi → Settings → Discover installed models** if the issue concerns generated answers;
5. verify that the active runtime reports the same chat model you selected;
6. do not delete the SQLite state before making a verified backup.

## Installed paths on macOS

```text
Application:  ~/Applications/Lumi.app
Runtime:      ~/Library/Application Support/Lumi/runtime/venv
Data:         ~/Library/Application Support/Lumi/data
Core log:     ~/Library/Logs/Lumi/core.log
```

## Core doctor

```bash
CORE="$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core"
"$CORE" doctor
```

To require both database and real local-model availability:

```bash
"$CORE" doctor --require-database --require-model
```

## Diagnostics privacy contract

The native diagnostics view is intended to be safe to paste into a support issue after normal review. It includes runtime metadata and configured non-secret model names/URLs but intentionally excludes:

- API-key values;
- prompt/chat text;
- durable-memory contents;
- knowledge-document contents;
- repository file contents;
- GitHub tokens or `.env` values.

The Core log is different: it should still be reviewed before sharing. Lumi's access logging is metadata-oriented, but external libraries and future features may emit additional details.

## Backup before destructive troubleshooting

```bash
"$CORE" backup --full
```

Do not manually modify or delete the active SQLite database as a first troubleshooting step.

Restore requires Core to be stopped:

```bash
"$CORE" restore /path/to/backup.sqlite3 --yes --full
```

## Local model troubleshooting

Lumi uses an Ollama-compatible endpoint. A successful repository/CI test does not prove that the target Mac has the requested model installed.

In **Lumi → Settings**:

1. confirm the Ollama server URL (normally `http://127.0.0.1:11434`);
2. click **Discover installed models**;
3. select an installed chat model;
4. choose an embedding model if dense retrieval is enabled;
5. click **Save models & restart managed Core**;
6. open Diagnostics and confirm the active runtime model.

Model discovery uses Ollama's fixed `/api/tags` HTTP endpoint; it does not invoke a shell. If discovery fails, confirm that Ollama itself is running and reachable at the configured URL.

Explicit `LUMI_OLLAMA_*` environment variables override the saved UI values. If the active model does not match Settings in a development environment, inspect those variables first.

Run the physical-machine acceptance gate from the repository:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/acceptance_local.py --require-model
```

The result must report success without fallback before `4.0.0` GA can be declared.

## Remote Core / model-server troubleshooting

The native client rejects remote plain HTTP for both Core and Ollama model-server configuration. Use HTTPS for remote endpoints.

Base URLs cannot contain embedded username/password credentials, a query string or fragment. Keep Core authentication in the dedicated API-key field. RC4 does not add arbitrary model-server credential storage.

## Release artifact verification

For the macOS ZIP:

```bash
shasum -a 256 -c Lumi-macOS-4.0.0rc4.zip.sha256
```

For Python release artifacts on Linux:

```bash
sha256sum -c SHA256SUMS
```

A checksum mismatch means the artifact should not be used.

## Bug reports

A useful non-sensitive bug report includes:

- Lumi version/commit;
- macOS version and architecture;
- diagnostics report;
- exact user-visible error;
- minimal reproduction steps;
- whether Ollama/model access was required;
- whether the problem reproduces after a clean restart.

Use the private security-reporting path described in `SECURITY.md` for vulnerabilities or secrets rather than a public issue.
