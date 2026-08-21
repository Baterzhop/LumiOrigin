# Lumi V4 RC2 Release Checklist

A release candidate is considered repository-ready only when every automatable item below is green on the exact candidate commit.

## Automated gates

- [ ] Python dependency installation and `pip check` on Ubuntu and macOS.
- [ ] `lumi-core doctor --initialize --no-model --require-database`.
- [ ] Full Python unit/API/security/RAG/memory/tool/Developer-Agent tests.
- [ ] Deterministic multilingual RAG regression gate.
- [ ] Deterministic multilingual memory regression gate.
- [ ] Live fallback HTTP/SSE acceptance against a real Core process.
- [ ] Live primary-model + dense-embedding HTTP/SSE acceptance against the deterministic Ollama-compatible CI server.
- [ ] Python wheel and source distribution build + clean-environment wheel smoke.
- [ ] Swift debug build and tests.
- [ ] Native Core URL security tests: loopback HTTP accepted, remote HTTP rejected, remote HTTPS accepted.
- [ ] macOS release app bundle build, plist lint and code-sign verification.
- [ ] `install_lumi.sh` production-style install on a clean macOS runner.
- [ ] Stable runtime exists at `~/Library/Application Support/Lumi/runtime/venv/bin/lumi-core`.
- [ ] Installed-runtime doctor passes.
- [ ] Live HTTP/SSE acceptance passes against the installed runtime.

## Target-Mac gate

This cannot be truthfully completed by GitHub-hosted runners because it depends on the physical Mac and the actual installed local model:

```bash
git clone https://github.com/Baterzhop/LumiOrigin.git
cd LumiOrigin
bash scripts/install_lumi.sh
open "$HOME/Applications/Lumi.app"
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/acceptance_local.py --require-model
```

The acceptance command must complete with `"ok": true` and report `fallback: false` for the configured local model.

The app itself must additionally be opened once and confirm that it can start the local Core without a terminal remaining open.

## Distribution gate

For local use, ad-hoc code signing is sufficient. Public distribution additionally requires a valid Apple Developer ID, notarization credentials, and a successful notarization/stapling check. Lumi does not claim notarization until those credentials are configured and the process has actually passed.
