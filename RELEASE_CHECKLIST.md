# Lumi V4 RC1 Release Checklist

A release candidate is considered repository-ready only when every automatable item below is green on the exact candidate commit.

## Automated gates

- [ ] Python dependency installation and `pip check` on Ubuntu and macOS.
- [ ] `lumi-core doctor --initialize --no-model --require-database`.
- [ ] Full Python unit/API/security/RAG/memory/tool/Developer-Agent tests.
- [ ] Deterministic multilingual RAG regression gate.
- [ ] Deterministic multilingual memory regression gate.
- [ ] Live fallback HTTP/SSE acceptance against a real Core process.
- [ ] Live primary-model + dense-embedding HTTP/SSE acceptance against the deterministic Ollama-compatible CI server.
- [ ] Python wheel and source distribution build.
- [ ] Swift debug build and tests.
- [ ] macOS release app bundle build, plist lint and code-sign verification.

## Target-Mac gate

This cannot be truthfully completed by GitHub-hosted runners because it depends on the user's physical Mac and installed local model:

```bash
bash scripts/install_lumi.sh
bash scripts/start_lumi.sh
# in another terminal
source .venv/bin/activate
python scripts/acceptance_local.py --require-model
```

The command must complete with `"ok": true` and must report `fallback: false` for the configured local model.

## Distribution gate

For local development, ad-hoc code signing is sufficient. Public distribution additionally requires a valid Apple Developer ID, notarization credentials, and a successful notarization/stapling check. Lumi does not claim notarization until those credentials are configured and the process has actually passed.
