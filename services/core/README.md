# Lumi Core

Lumi Core is the Python orchestration service used by Lumi V4. It provides streaming chat, durable SQLite state, grounded retrieval, explicit memory, policy-gated tools and the approval-gated Developer Agent.

This package is primarily distributed as part of the Lumi monorepo. See the repository-level `README.md`, `docs/release.md` and `RELEASE_CHECKLIST.md` for installation, security and release instructions.

After installation:

```bash
lumi-core doctor
lumi-core serve
```

The supported RC1 environment is Python 3.11+, with Python 3.12 used by release CI. The repository includes `requirements.lock` as the tested constraints set for reproducible local/CI installation.
