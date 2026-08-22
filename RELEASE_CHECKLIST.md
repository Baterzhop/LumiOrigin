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

After installing RC5 and selecting the real Ollama model in **Finish Lumi setup** / **Lumi → Settings**, run the one-command physical acceptance from the repository with the installed Core Python:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/ga_acceptance_macos.py
```

The probe is fail-closed and automatically verifies:

- managed Core startup from `Lumi.app`;
- real-model HTTP + SSE acceptance with `fallback=false`;
- a grounded answer against a real temporary Markdown document with matching citation metadata;
- durable memory surviving a full app/Core quit and restart;
- read-only workspace tool execution;
- an exact persisted write proposal staying blocked until explicit TaskRuntime approval;
- backup creation and full restore/integrity verification against a disposable database copy;
- app-owned Core shutdown ownership.

It writes non-secret machine-readable target evidence to:

```text
~/Library/Application Support/Lumi/ga-evidence/4.0.0-ga.json
```

The target section is complete only when `target_mac.ok` is `true`. The script intentionally does **not** fake repository-governance or Apple-notarization evidence.

## Distribution gate

For local use, ad-hoc code signing is sufficient. Public distribution requires real Apple credentials. The repository-side path is:

```bash
xcrun notarytool store-credentials "lumi-notary" ...
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

After successful Developer-ID verification, Apple notarization, stapling and Gatekeeper assessment, the script now also emits:

```text
dist/Lumi-macOS-<version>.notarization.json
```

This fragment contains only non-secret verification state and the final artifact SHA-256.

## Repository governance gate

`main` must be protected by a GitHub ruleset requiring pull requests and V4 CI before merge, with force-push/deletion protection. This is tracked in issue #53 because the available repository integration cannot mutate branch-protection/ruleset settings.

## Final evidence gate

`release-evidence/4.0.0-template.json` defines the final evidence contract. Before creating the final `v4.0.0` tag, populate `release-evidence/4.0.0-ga.json` from verified target-Mac/governance evidence and, for public distribution, the notarization evidence fragment.

Validate it locally:

```bash
python3 scripts/validate_ga_evidence.py release-evidence/4.0.0-ga.json
```

For public distribution:

```bash
python3 scripts/validate_ga_evidence.py release-evidence/4.0.0-ga.json --public
```

The release workflow now fails closed for the final `v4.0.0` tag if this evidence is missing or incomplete. RC builds remain possible without falsely promoting the project to GA.

## GA invariant

Do not change the release line to `4.0.0` final solely because repository CI is green. GA requires verified target-Mac evidence and repository governance. Public downloadable distribution additionally requires Apple notarization/Gatekeeper evidence. The final tag is mechanically blocked until the evidence validator passes.
