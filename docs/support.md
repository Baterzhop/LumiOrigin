# Lumi V4 Support Guide

## First response checklist

When Lumi does not start or behaves unexpectedly:

1. open **Core → Open Diagnostics…** and refresh the report;
2. open **Core → Open Readiness Center…** and run the appropriate acceptance mode;
3. run the installed Core doctor if more detail is needed;
4. inspect the Core log;
5. use **Lumi → Settings → Discover installed models** if the issue concerns generated answers;
6. verify that the active runtime reports the same chat model you selected;
7. do not delete SQLite state before making a verified backup.

## Installed paths on macOS

```text
Application:  ~/Applications/Lumi.app
Runtime:      ~/Library/Application Support/Lumi/runtime/venv
Data:         ~/Library/Application Support/Lumi/data
Core log:     ~/Library/Logs/Lumi/core.log
```

## Core doctor and readiness

```bash
CORE="$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core"
"$CORE" doctor
```

To require both database and real local-model availability:

```bash
"$CORE" doctor --require-database --require-model
```

To execute the complete installed-runtime acceptance contract:

```bash
"$CORE" acceptance
```

To fail if chat or streaming falls back instead of using the configured local model:

```bash
"$CORE" acceptance --require-model
```

This is the same core contract exposed by the native Readiness Center. The packaged command validates live Core health/readiness, chat, SSE, memory retrieval, grounded knowledge retrieval, tool discovery and verified backup creation. It is intentionally repeatable and does not require a repository checkout.

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

On a fresh installation, Lumi presents **Finish Lumi setup**. The same settings remain available later under **Lumi → Settings**.

1. confirm the Ollama server URL (normally `http://127.0.0.1:11434`);
2. click **Discover installed models**;
3. select an installed chat model;
4. choose an embedding model if dense retrieval is enabled, or disable dense retrieval when none is installed;
5. save/restart the managed Core;
6. open Diagnostics and confirm the active runtime model;
7. run the Readiness Center with **Require the configured real model** enabled.

Model discovery uses Ollama's `/api/tags` HTTP endpoint; it does not invoke a shell. If discovery fails, confirm that Ollama itself is running and reachable at the configured URL.

Explicit `LUMI_OLLAMA_*` environment variables override saved UI values. If the active model does not match Settings in a development environment, inspect those variables first.

The authoritative CLI form of the physical-machine model gate is:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core" acceptance --require-model
```

The result must report `"ok": true` and `"fallback": false` before `4.0.0` GA can be declared.

## Remote Core / model-server troubleshooting

The native client rejects remote plain HTTP for both Core and Ollama model-server configuration. Use HTTPS for remote endpoints.

Base URLs cannot contain embedded username/password credentials, a query string or fragment. Keep Core authentication in the dedicated API-key field. Lumi does not add arbitrary model-server credential storage.

## Release artifact verification

For the RC5 macOS ZIP:

```bash
shasum -a 256 -c Lumi-macOS-4.0.0rc5.zip.sha256
```

For Python release artifacts on Linux:

```bash
sha256sum -c SHA256SUMS
```

A checksum mismatch means the artifact should not be used.

## Developer-ID / notarization troubleshooting

Public distribution is separate from local use. Once a valid Developer ID Application certificate and notarytool Keychain profile exist:

```bash
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

The script fails closed when credentials are absent. On success it verifies signing, waits for Apple notarization, staples/validates the ticket, checks Gatekeeper, recreates the ZIP after stapling and verifies the final checksum.

## Bug reports

A useful non-sensitive bug report includes:

- Lumi version/commit;
- macOS version and architecture;
- diagnostics report;
- Readiness Center / `lumi-core acceptance` output;
- exact user-visible error;
- minimal reproduction steps;
- whether Ollama/model access was required;
- whether the problem reproduces after a clean restart.

Use the private security-reporting path described in `SECURITY.md` for vulnerabilities or secrets rather than a public issue.
