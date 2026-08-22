# Lumi V4 4.0.0 GA Release Checklist

This checklist is the canonical promotion path from the final RC candidate to `4.0.0` GA.

## Automated repository gates

A candidate is repository-ready only when all five required V4 CI jobs are green on the PR merge candidate:

- [x] `core (ubuntu-latest, 3.12)`
- [x] `core (macos-14, 3.12)`
- [x] `macos-client`
- [x] `macos-install-smoke`
- [x] `macos-ga-orchestration-smoke`

These jobs cover dependency integrity, database doctor/migrations, unit/API/security/RAG/memory/tool/Developer-Agent tests, multilingual evals, fallback and primary-model acceptance, wheel/sdist verification, Swift build/tests, app packaging, production-style installation, managed Core lifecycle and the full hosted GA orchestration.

The hosted macOS GA orchestration has already proven the release helper itself end-to-end with a deterministic primary model, including:

- managed `Lumi.app` → Core startup/shutdown;
- `fallback=false` primary-model operation;
- grounded document citation;
- durable memory across restart;
- read-only tool execution;
- exact approval-gated write execution;
- verified backup and restore into a disposable copy.

## External gate 1 — physical target Mac

Use the exact commit you intend to promote. Install Lumi and configure the real local Ollama models, then run:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/ga_acceptance_macos.py
```

Expected output:

```text
~/Library/Application Support/Lumi/ga-evidence/4.0.0-ga.json
```

Required:

- [ ] `target_mac.ok=true`
- [ ] real model selected and `fallback_false=true`
- [ ] grounded citation passes
- [ ] restart passes
- [ ] durable memory passes
- [ ] read tool passes
- [ ] approval-gated write passes
- [ ] backup/restore-copy passes
- [ ] app-owned Core shutdown passes

If runtime code changes after this candidate commit, the physical acceptance is invalid and must be repeated.

## External gate 2 — repository governance

`main` must be protected. Apply and verify the canonical rule with an administrator-authenticated GitHub CLI session:

```bash
TARGET="$HOME/Library/Application Support/Lumi/ga-evidence/4.0.0-ga.json"
bash scripts/configure_branch_protection.sh \
  --repository Baterzhop/LumiOrigin \
  --branch main \
  --evidence "$TARGET" \
  --apply
```

Required GitHub state:

- [ ] pull requests required
- [ ] strict required status checks enabled
- [ ] all five V4 jobs required
- [ ] force pushes blocked
- [ ] branch deletion blocked
- [ ] conversation resolution required

The script updates governance evidence only after GitHub confirms the active policy.

## Promotion to 4.0.0

After physical acceptance, promote the candidate through a normal PR. Only release metadata may change after `candidate_commit`:

- `services/core/pyproject.toml`
- `services/core/src/lumi_core/__init__.py`
- `CHANGELOG.md`
- `README.md`
- `RELEASE_CHECKLIST.md`
- `docs/release.md`
- `release-evidence/4.0.0-ga.json`

Set both canonical Core versions to `4.0.0` and run the normal five-gate V4 CI. Any runtime or unapproved-file change invalidates the physical candidate.

## Optional public distribution gate — Apple

Public downloadable distribution additionally requires real Developer ID/notarization evidence after the promotion branch is versioned `4.0.0`:

```bash
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

Required:

- [ ] Developer-ID codesign verification
- [ ] Apple notary status `Accepted`
- [ ] stapling + stapler validation
- [ ] Gatekeeper assessment
- [ ] post-staple ZIP checksum verification

Evidence output:

```text
dist/Lumi-macOS-4.0.0.notarization.json
```

## Compose canonical GA evidence

No manual JSON editing is required.

Local/non-public GA:

```bash
python3 scripts/compose_ga_evidence.py "$TARGET" \
  --output release-evidence/4.0.0-ga.json
```

Public GA:

```bash
python3 scripts/compose_ga_evidence.py "$TARGET" \
  --notarization dist/Lumi-macOS-4.0.0.notarization.json \
  --public \
  --output release-evidence/4.0.0-ga.json
```

Validate:

```bash
python3 scripts/validate_ga_evidence.py release-evidence/4.0.0-ga.json
python3 scripts/verify_ga_promotion.py release-evidence/4.0.0-ga.json --release-ref HEAD
```

Public distribution also requires:

```bash
python3 scripts/validate_ga_evidence.py release-evidence/4.0.0-ga.json --public
```

## Final tag

Create `v4.0.0` only after all evidence and promotion checks pass.

The release workflow independently enforces:

1. tag equals the canonical project version;
2. final GA evidence validates;
3. `candidate_commit` exists and is an ancestor of the tag;
4. physical target app/Core versions match that candidate;
5. final runtime version is exactly `4.0.0`;
6. no runtime or unapproved files changed after physical acceptance.

## GA invariant

Repository CI alone is not GA evidence. Lumi V4 may be called `4.0.0` GA only after real physical target-Mac evidence and real repository governance pass. Public distribution additionally requires real Apple notarization/Gatekeeper evidence.
