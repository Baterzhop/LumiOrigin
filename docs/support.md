# Lumi V4 Support Guide

## First response checklist

When Lumi does not start or behaves unexpectedly:

1. open **Core → Open Diagnostics…** in Lumi and refresh the report;
2. run the installed Core doctor;
3. inspect the Core log;
4. verify the configured local model if the issue concerns generated answers;
5. do not delete the SQLite state before making a verified backup.

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

The native diagnostics view is intended to be safe to paste into a support issue after normal review. It includes runtime metadata but intentionally excludes:

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

Lumi uses an Ollama-compatible local endpoint. A successful repository/CI test does not prove that the target Mac has the requested model installed.

Run the physical-machine acceptance gate from the repository:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/acceptance_local.py --require-model
```

The result must report success without fallback before `4.0.0` GA can be declared.

## Remote Core troubleshooting

The native client rejects remote plain HTTP. Use HTTPS and configure the matching Lumi API key in macOS Keychain through **Lumi → Settings**.

The base URL cannot contain embedded username/password credentials, a query string or fragment. Keep authentication in the API-key field.

## Release artifact verification

For the macOS ZIP:

```bash
shasum -a 256 -c Lumi-macOS-4.0.0rc3.zip.sha256
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
