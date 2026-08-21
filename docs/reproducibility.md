# Reproducible Lumi Core environment

`services/core/pyproject.toml` describes compatibility ranges for the reusable Python package. `services/core/requirements.lock` records the exact dependency versions used by the RC1 release gate.

Local installation and CI therefore use the lock file as a pip constraints set:

```bash
python -m pip install -c services/core/requirements.lock -e "services/core[dev]"
```

The release wheel is additionally installed in a fresh virtual environment under the same constraints and must pass `pip check`, `lumi-core version`, and a database-initialization doctor run.

The lock is intentionally separate from package metadata: downstream users can still resolve compatible newer dependencies, while Lumi's own release process remains pinned to the tested set. Updating the lock requires a dedicated dependency-update change followed by the complete release CI gate.

RC1 lock provenance: green GitHub-hosted Ubuntu Python 3.12.14 environment, 2026-08-21.
