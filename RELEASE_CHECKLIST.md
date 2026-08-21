# Lumi V4 RC4 Release Checklist

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
- [ ] Python release artifacts produce a valid `SHA256SUMS` manifest.
- [ ] Swift debug build and tests.
- [ ] Native Core URL security tests: loopback HTTP accepted, remote HTTP rejected, remote HTTPS accepted, embedded credentials/query/fragment rejected.
- [ ] Native Ollama server URL uses the same safe boundary.
- [ ] Model-name validation rejects empty/whitespace/control-character names.
- [ ] Saved model settings map to `LUMI_OLLAMA_URL`, `LUMI_OLLAMA_EMBED_URL`, `LUMI_OLLAMA_MODEL`, `LUMI_EMBEDDING_MODEL` and `LUMI_RAG_DENSE` for the managed Core.
- [ ] Explicit process environment values are never overwritten by the saved model settings.
- [ ] Ollama model discovery decodes/sorts/deduplicates `GET /api/tags` using injectable typed HTTP transport.
- [ ] Native diagnostics surface builds and remains metadata-only by design.
- [ ] macOS release app bundle build, plist lint and code-sign verification.
- [ ] macOS ZIP produces a matching `.sha256` file and checksum verification passes.
- [ ] `install_lumi.sh` production-style install on a clean macOS runner.
- [ ] Stable runtime exists at `~/Library/Application Support/Lumi/runtime/venv/bin/lumi-core`.
- [ ] Installed-runtime doctor passes.
- [ ] Live HTTP/SSE acceptance passes against the installed runtime.

## Target-Mac gate

This cannot be truthfully completed by GitHub-hosted runners because it depends on the physical Mac and the actual installed local model. The authoritative external checklist is GitHub issue #44.

```bash
git clone https://github.com/Baterzhop/LumiOrigin.git
cd LumiOrigin
bash scripts/install_lumi.sh
open "$HOME/Applications/Lumi.app"
```

In **Lumi → Settings**, discover the installed Ollama models, select the actual chat model, save it and restart the managed Core. Then run:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/acceptance_local.py --require-model
```

The acceptance command must complete with `"ok": true` and report `fallback: false` for the selected local model.

The app itself must additionally confirm that it can start the local Core without a terminal remaining open. Knowledge/citations, durable memory, one read-only tool, one approval-gated write, backup/restore and managed-Core shutdown should also be checked on the real machine before GA.

## Distribution gate

For local use, ad-hoc code signing is sufficient. Public distribution additionally requires a valid Apple Developer ID, notarization credentials, and a successful notarization/stapling check. Lumi does not claim notarization until those credentials are configured and the process has actually passed.

## GA invariant

Do not change the release line to `4.0.0` final solely because repository CI is green. GA requires the physical target-Mac real-model gate above. Public downloadable distribution additionally requires the distribution gate.
