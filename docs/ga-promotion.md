# Lumi V4 — final 4.0.0 promotion path

Lumi V4 must not be called `4.0.0` GA simply because repository CI is green. The final release path is intentionally split so the physical target-Mac evidence is bound to the exact code tree that ships.

## 1. Finish all repository-side RC work on `main`

The canonical line is Python Lumi Core + native SwiftUI. Retired Swift-only V3/V4 migration branches are historical and must not be merged into the release line.

`main` stays on `4.0.0rc5` while repository-side release work is still changing.

## 2. Create a dedicated final candidate branch

From the final repository-ready `main`:

```bash
git switch main
git pull --ff-only
git switch -c lumi-v4-ga-candidate
a python3 scripts/prepare_ga_candidate.py
python3 scripts/prepare_ga_candidate.py --apply
```

(The stray `a` above is not a command; use only the two `python3` lines below if copying commands.)

Correct copyable sequence:

```bash
git switch main
git pull --ff-only
git switch -c lumi-v4-ga-candidate
python3 scripts/prepare_ga_candidate.py
python3 scripts/prepare_ga_candidate.py --apply
```

The preparation tool refuses `main`, refuses a dirty working tree, and changes only the release-version markers needed for the final candidate. Review the diff and run the full V4 CI on the exact candidate commit.

Do not add feature work after this point.

## 3. Run the physical target-Mac gate on that exact candidate commit

Install that candidate on the physical target Mac, complete first-run Ollama model selection, then run:

```bash
"$HOME/Library/Application Support/Lumi/runtime/venv/bin/python" scripts/ga_acceptance_macos.py
```

The generated evidence records the exact candidate Git SHA and fails closed unless real-model chat/SSE, grounded citation, restart-persistent memory, tool approval, backup/restore-copy and app-owned Core shutdown all pass.

## 4. Apply and bind repository governance

From a repository-administrator GitHub CLI session, using the same evidence file:

```bash
bash scripts/configure_branch_protection.sh \
  --evidence "$HOME/Library/Application Support/Lumi/ga-evidence/4.0.0-ga.json" \
  --apply
```

The script updates governance evidence only after GitHub's live protection response verifies required V4 CI checks, pull-request protection, resolved conversations and force-push/deletion blocking.

## 5. Public distribution only: notarize the exact 4.0.0 candidate

If Lumi will be distributed publicly, configure the Developer ID and notary profile and run:

```bash
export LUMI_VERSION=4.0.0
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

This produces a non-secret notarization fragment next to the final ZIP. Private/local GA does not require Apple notarization evidence and keeps `distribution.public=false`.

## 6. Assemble final evidence

For private/local GA:

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

The assembler does not manufacture missing truth values. It rejects candidate-SHA mismatches, unverified governance, malformed/unknown notarization fields, and incomplete public evidence. It writes `release-evidence/4.0.0-ga.json` only after the existing fail-closed validator accepts the assembled state.

## 7. Evidence-only commit and final tag

After the physical candidate was accepted, **do not change product code**. Create one commit whose only difference from the accepted candidate is:

```text
release-evidence/4.0.0-ga.json
```

Tag that evidence commit as:

```bash
git tag v4.0.0
git push origin v4.0.0
```

The release workflow fetches full Git history and enforces all of the following before producing final artifacts:

- evidence validator passes;
- tag version equals Core version;
- the evidence `candidate_commit` exists and is an ancestor of the tag;
- that candidate itself reports version `4.0.0`;
- the only path changed between the physically accepted candidate and the tag is `release-evidence/4.0.0-ga.json`.

Therefore the final shipped code tree is exactly the tree tested on the physical Mac; only the evidence record is added afterward.

## 8. No hidden scope expansion

Provider-native tool calling and the future durable user TaskEngine remain post-4.0 work. They are not GA blockers and must not be used to broaden the runtime authority surface during finalization.
