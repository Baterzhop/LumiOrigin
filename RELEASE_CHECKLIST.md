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
- [x] The exact persisted write-approval helper used by physical GA acceptance executes through real `TaskRuntime`, `ToolRegistry` and `PolicyEngine` in CI.
- [x] Repository-governance configuration script is dry-run by default, fail-closed, and integration-tested with verified evidence binding.

## Final-version candidate gate

Do not mutate `main` directly from RC5 to final. Create a dedicated candidate branch and run:

```bash
python3 scripts/prepare_ga_candidate.py
python3 scripts/prepare_ga_candidate.py --apply
```

The apply mode refuses `main` and a dirty working tree. It promotes only the version markers required for the final `4.0.0` candidate. The full V4 CI must pass on that exact candidate commit before physical acceptance.

## Target-Mac gate

This cannot be truthfully completed by GitHub-hosted runners because it depends on the physical Mac and the actual installed local model. The authoritative external checklist is GitHub issue #44.

After installing the final-version candidate and selecting the real Ollama model in **Finish Lumi setup** / **Lumi → Settings**, run the one-command physical acceptance from the repository with the installed Core Python:

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

## Repository governance gate

`main` must be protected by GitHub rules requiring pull requests and V4 CI before merge, with force-push/deletion protection. Review the policy first:

```bash
bash scripts/configure_branch_protection.sh
```

After physical evidence exists, a repository administrator can apply and bind verified governance into that same evidence file:

```bash
bash scripts/configure_branch_protection.sh \
  --evidence "$HOME/Library/Application Support/Lumi/ga-evidence/4.0.0-ga.json" \
  --apply
```

The governance fields are changed only after GitHub's live branch-protection response is re-read and verified. Issue #53 remains open until this has actually succeeded.

## Distribution gate

For local use, ad-hoc code signing is sufficient. Public distribution requires real Apple credentials. The repository-side path is:

```bash
xcrun notarytool store-credentials "lumi-notary" ...
export LUMI_VERSION=4.0.0
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

After successful Developer-ID verification, Apple notarization, stapling and Gatekeeper assessment, the script emits:

```text
dist/Lumi-macOS-4.0.0.notarization.json
```

This fragment contains only non-secret verification state and the final artifact SHA-256.

## Final evidence gate

Assemble the final repository evidence from the verified physical/governance file. For local/private GA:

```bash
python3 scripts/assemble_ga_evidence.py \
  "$HOME/Library/Application Support/Lumi/ga-evidence/4.0.0-ga.json" \
  --expected-candidate "$(git rev-parse HEAD)"
```

For public GA:

```bash
python3 scripts/assemble_ga_evidence.py \
  "$HOME/Library/Application Support/Lumi/ga-evidence/4.0.0-ga.json" \
  --notarization dist/Lumi-macOS-4.0.0.notarization.json \
  --public \
  --expected-candidate "$(git rev-parse HEAD)"
```

The assembler rejects mismatched candidate SHAs, unverified governance, malformed notarization fragments and incomplete public evidence. It writes `release-evidence/4.0.0-ga.json` atomically only after the existing validator accepts the result.

Validate it independently:

```bash
python3 scripts/validate_ga_evidence.py release-evidence/4.0.0-ga.json
```

For public distribution:

```bash
python3 scripts/validate_ga_evidence.py release-evidence/4.0.0-ga.json --public
```

## Final tag provenance gate

After the physical candidate is accepted, product code is frozen. The only path allowed to differ between the accepted candidate and final `v4.0.0` tag is:

```text
release-evidence/4.0.0-ga.json
```

The release workflow fetches full Git history and mechanically verifies:

- final evidence passes;
- tag version matches Core version;
- the physical `candidate_commit` exists and is an ancestor of the tag;
- that candidate itself identifies as `4.0.0`;
- the diff from accepted candidate to tag contains only the evidence file.

Any post-acceptance code/configuration change therefore blocks the final release and requires a fresh physical acceptance run.

## GA invariant

Do not change the release line to `4.0.0` final solely because repository CI is green. GA requires verified target-Mac evidence and repository governance. Public downloadable distribution additionally requires Apple notarization/Gatekeeper evidence. The final tag is mechanically blocked until the evidence validator and candidate-provenance gate both pass.

See `docs/ga-promotion.md` for the exact end-to-end sequence.
