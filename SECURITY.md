# Security Policy

## Scope

This policy applies to the current Lumi V4 `main` / release-candidate line, including the Python Core, native macOS client, local persistence, RAG ingestion/retrieval, agent tools and Developer Agent.

## Reporting a vulnerability

For a vulnerability that would expose secrets, permit unauthorized tool execution, bypass an approval boundary, escape a filesystem sandbox, corrupt protected state, or enable remote code execution, use GitHub's private security-advisory reporting flow for this repository when available. Do not publish exploit details in a public issue before a fix is available.

For non-sensitive security-hardening suggestions, a normal GitHub issue is acceptable.

A useful report contains:

- affected Lumi version/commit;
- macOS/Python versions where relevant;
- minimal reproduction steps;
- expected and actual security boundary;
- whether the issue requires local access, remote access or user approval;
- sanitized logs/diagnostics with all secrets removed.

## Security invariants

Lumi V4 is designed around these invariants:

- local loopback networking by default;
- remote access requires explicit secure configuration and API-key authentication;
- remote plain HTTP is rejected by the native client;
- API-key values are not stored in UserDefaults and are not included in diagnostics;
- documents, tool output and repository content are untrusted data, not system instructions;
- side-effect tools require explicit approval of the exact arguments;
- tool paths are sandboxed and traversal/symlink escapes are rejected;
- unrestricted shell, arbitrary HTTP execution and delete tools are not exposed;
- Developer Agent uses isolated branches, fixed validation profiles and a second publish approval;
- Developer Agent creates draft PRs only and never auto-merges;
- durable memory is explicit, inspectable, editable and deletable;
- migrations/backups/restores run integrity checks and restore fails closed when the database is in use.

## Secrets

Never commit `.env`, API keys, GitHub tokens, private model credentials, user databases or generated support bundles containing private data. The repository `.gitignore` covers normal Lumi runtime state, but operators remain responsible for reviewing files before commits or issue uploads.

## Supported versions

Until `4.0.0` GA, only the newest V4 release candidate and current `main` receive active security hardening. Older prototypes and legacy branches are unsupported unless explicitly revived.
