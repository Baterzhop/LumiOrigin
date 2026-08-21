# Lumi V4 Alpha Hardening

This phase tightens the M0–M5 functional alpha without granting Lumi broader privileges.

## Network boundary

The Core is local-only by default. If `LUMI_API_KEY` is not configured, requests from non-loopback client addresses are rejected even if Uvicorn is accidentally bound to `0.0.0.0`.

For LAN/remote use, configure a strong API key (minimum 24 characters) and explicit trusted hosts:

```bash
export LUMI_API_KEY="replace-with-a-long-random-secret"
export LUMI_TRUSTED_HOSTS="localhost,127.0.0.1,my-mac.local"
```

Every `/v1/*` route then requires either:

```text
X-Lumi-Key: <secret>
```

or a Bearer token containing the same secret. `/health` and `/ready` expose only minimal service/readiness state.

The native macOS client reads `LUMI_API_KEY` from its process environment and attaches `X-Lumi-Key` automatically.

API documentation is disabled by default. Enable it only when needed:

```bash
export LUMI_API_DOCS=true
```

CORS is disabled unless explicit origins are configured. Wildcard origins are rejected.

## Configuration validation

Startup fails closed for malformed provider URLs, unsafe wildcard trusted hosts without authentication, undersized API keys, invalid numeric budgets, and malformed fixed GitHub repository names. Secret fields are excluded from `Settings` repr output.

## Database protection

SQLite remains the canonical state store. On startup Lumi:

1. creates a consistent pre-migration backup when an existing database is present;
2. retains only the configured number of pre-migration backups;
3. applies migrations;
4. executes SQLite `quick_check` and refuses startup if integrity is not `ok`.

Manual backup:

```bash
python scripts/backup_lumi.py --full-check
```

Authenticated/local API backup:

```text
POST /v1/admin/backup
```

Backups use SQLite's backup API, are verified before success is reported, and are chmod `0600` where the platform permits it.

## Readiness and request tracing

`GET /ready` checks database readiness separately from the basic process liveness endpoint `GET /health`.

Every HTTP response receives `X-Request-ID`. The access logger emits metadata only: request ID, method, path, status and latency. Request bodies, response bodies, API keys, GitHub tokens and model prompts are not logged by this middleware.

## Remaining alpha limits

- API-key authentication is intentionally simple single-user local security, not multi-user identity/RBAC.
- Backups are local files; encrypted off-device backup is not implemented yet.
- Ollama/model health is not part of Core readiness because chat can degrade/fail independently of durable-state health.
- Full release packaging, signing/notarization and real-machine acceptance tests remain later hardening work.
