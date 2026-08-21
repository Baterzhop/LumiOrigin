# Lumi V4 RC5 Release Checklist

A release candidate is considered repository-ready only when every automatable item below is green on the exact candidate commit.

## Automated gates

Verified on RC5 candidate head `dc97f298a4675b3fffb7f5511633857065d14d47` before merge to `main` as `02a14aded827267a7a1f768e45646499dbba21f5`.

- [x] Python dependency installation and `pip check` on Ubuntu and macOS.
- [x] `lumi-core doctor --initialize --no-model --require-database`.
- [x] Full Python unit/API/security/RAG/memory/tool/Developer-Agent/acceptance tests.
- [x] Deterministic multilingual RAG regression gate.
- [x] Deterministic multilingual memory regression gate.
- [x] Live fallback HTTP/SSE acceptance through the packaged `lumi-core acceptance` command.
- [x] Live primary-model + dense-embedding acceptance with `--require-model` against the deterministic Ollama-compatible CI server.
- [x] Python wheel and source distribution build + clean-environment wheel smoke.
- [x] Installed wheel exposes `lumi-core acceptance` without repository source-path dependencies.
- [x] Python release artifacts produce and verify a valid `SHA256SUMS` manifest.
- [x] Swift debug build and tests.
- [x] Native Core URL security tests: loopback HTTP accepted, remote HTTP rejected, remote HTTPS accepted, embedded credentials/query/fragment rejected.
- [x] Native Ollama server URL uses the same safe boundary.
- [x] Model-name validation rejects empty/whitespace/control-character names.
- [x] Saved model settings map to `LUMI_OLLAMA_URL`, `LUMI_OLLAMA_EMBED_URL`, `LUMI_OLLAMA_MODEL`, `LUMI_EMBEDDING_MODEL` and `LUMI_RAG_DENSE` for the managed Core.
- [x] Explicit process environment values are never overwritten by saved model settings.
- [x] Ollama model discovery decodes/sorts/deduplicates `GET /api/tags` using injectable typed HTTP transport.
- [x] First-run setup surface builds and can intentionally select a real model or continue in fallback mode.
- [x] Native acceptance configuration keeps Core API keys out of command-line arguments.
- [x] Native Readiness Center builds and runs the installed acceptance command model.
- [x] Native diagnostics surface builds and remains metadata-only by design.
- [x] macOS release app bundle build, plist lint and code-sign verification.
- [x] macOS RC5 ZIP produces a matching `.sha256` file and checksum verification passes.
- [x] `install_lumi.sh` production-style install on a clean macOS runner.
- [x] Stable runtime exists at `~/Library/Application Support/Lumi/runtime/venv/bin/lumi-core`.
- [x] Installed-runtime doctor passes.
- [x] Installed runtime exposes the packaged acceptance command.
- [x] Live HTTP/SSE/RAG/memory/tools/backup acceptance passes when invoked by the installed `lumi-core` executable.
- [x] Developer-ID/notarization entrypoint passes `bash -n` and fails closed without required credentials.

## Target-Mac gate

This cannot be truthfully completed by GitHub-hosted runners because it depends on the physical Mac and the actual installed local model. The authoritative external checklist is GitHub issue #44.

```bash
git clone https://github.com/Baterzhop/LumiOrigin.git
cd LumiOrigin
bash scripts/install_lumi.sh
open "$HOME/Applications/Lumi.app"
```

On first launch, use **Finish Lumi setup** (or later **Lumi → Settings**) to discover installed Ollama models, select the actual chat model and apply it to the managed Core.

Then use **Core → Open Readiness Center…** with **Require the configured real model** enabled, or run the equivalent installed command:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/lumi-core" acceptance --require-model
```

The acceptance result must complete with `"ok": true` and `"fallback": false` for the selected local model.

The app itself must additionally be opened/restarted and confirm that the managed Core lifecycle behaves correctly. A real user document/citation, durable-memory persistence across restart, one read-only tool, one approval-gated write, backup/restore on a copy of data, and shutdown ownership should be checked before GA.

## Distribution gate

For local use, ad-hoc code signing is sufficient. Public distribution requires real Apple credentials. The repository-side path is:

```bash
xcrun notarytool store-credentials "lumi-notary" ...
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

The script must complete Developer-ID verification, notarization, stapling, stapler validation, Gatekeeper assessment, post-staple packaging and SHA-256 verification. Lumi does not claim this gate until it has actually passed with valid credentials.

## Repository governance gate

`main` should be protected by a GitHub ruleset requiring pull requests and V4 CI before merge, with force-push/deletion protection. This is tracked in issue #53 because the available repository integration cannot mutate branch-protection/ruleset settings.

## GA invariant

Do not change the release line to `4.0.0` final solely because repository CI is green. GA requires the physical target-Mac real-model gate above. Public downloadable distribution additionally requires the distribution gate. Repository governance should also be enabled before treating `main` as a professionally controlled release branch.
