# Lumi V4 GA completion

This document defines what "100%" means for Lumi V4 without pretending that repository CI can perform actions that require the physical target Mac, Apple credentials, or repository-administrator settings.

## Current line

The canonical architecture is the Python Lumi Core plus the native SwiftUI macOS client on `main`. The old parallel Swift-only V3/V4 migration stack is historical and must not be merged back into the release line.

The current software line remains `4.0.0rc5` until the physical target-Mac real-model gate is completed. Public downloadable distribution additionally requires Apple Developer-ID notarization.

## Gate A — repository and automated product quality

This gate is already represented by `RELEASE_CHECKLIST.md` and the `Lumi V4 CI` workflow. It covers dependency validation, full Python/Swift tests, multilingual retrieval gates, live fallback and primary-model-compatible HTTP/SSE acceptance, wheel/sdist verification, macOS packaging, checksum validation and production-style installation.

No final-version bump should bypass this gate.

## Gate B — physical target Mac

After installing current `main` and completing the first-run model selection in Lumi, run:

```bash
bash scripts/ga_target_mac.sh
```

The script deliberately uses the Python interpreter from Lumi's installed Core runtime rather than a repository-only environment. It:

1. opens the installed `Lumi.app`;
2. waits for the managed Core `/ready` endpoint;
3. requires ordinary chat and SSE to use the configured real model (`fallback=false`);
4. runs the full installed HTTP/SSE/RAG/memory/tool-registry/backup acceptance contract;
5. verifies the produced SQLite backup by restoring it into a disposable temporary database and running a full integrity check;
6. verifies the workspace read-only policy path;
7. verifies that `workspace.write_text` is denied without confirmation;
8. after the user's explicit invocation, approves one exact temporary write, checks its exact content, then removes the marker;
9. writes mode-0600 JSON evidence to `~/Desktop/Lumi-GA-machine-evidence.json` by default.

The evidence collector is intentionally incapable of declaring GA by itself. The following still need direct user evidence because they are properties of the native session or of real user content:

- app-managed Core shutdown/restart ownership;
- a durable memory surviving an actual app/Core restart;
- an answer over one real user document with a verified citation;
- exact-argument approval in the native UI.

Those checks remain authoritative in GitHub issue #44.

If a Core API key is configured, expose it to the local shell only for the duration of the check with `LUMI_API_KEY`; the value is never written to the evidence file.

## Gate C — repository governance

`main` should not remain directly writable without release checks. Review the dry run:

```bash
bash scripts/configure_branch_protection.sh
```

Then, from an administrator-authenticated GitHub CLI session:

```bash
bash scripts/configure_branch_protection.sh --apply
```

The script configures and then re-reads the branch protection endpoint. It requires the four V4 CI job contexts, up-to-date checks, pull-request protection, resolved review conversations, and denies force pushes/deletion. The script intentionally does not silently grant broad admin bypasses or change repository settings unless `--apply` is supplied.

Issue #53 must remain open until the protection is actually applied and GitHub confirms `main` is protected.

## Gate D — Apple public-distribution trust

Local/private use can continue with the verified ad-hoc signed build. Public distribution requires actual Apple credentials:

```bash
export LUMI_CODESIGN_IDENTITY="Developer ID Application: ..."
export LUMI_NOTARY_PROFILE="lumi-notary"
bash scripts/notarize_macos_app.sh
```

The Keychain notary profile must already be configured. The script must complete signing verification, notarization, stapling, stapler validation, Gatekeeper assessment, post-staple packaging and checksum verification. Do not convert an absent credential into a skipped-success state.

A clean Mac/account should also open the stapled artifact successfully before public GA.

## Final promotion rule

The release may be renamed from `4.0.0rc5` to `4.0.0` only after all of the following are true:

- exact-candidate V4 CI is green;
- physical target-Mac real-model acceptance is green with `fallback=false`;
- the remaining native-session checks in issue #44 are complete;
- `main` branch protection is enabled and verified;
- for public distribution, Developer-ID notarization and clean-Mac Gatekeeper validation are complete.

Until then, the technically correct state is **release candidate with complete repository-side automation**, not GA.

## Post-4.0 work

Provider-native model tool calls (#12) and the durable user TaskEngine (#47) are intentionally post-4.0 features. They must not be pulled into the GA critical path or used as a reason to weaken the current ToolRegistry → PolicyEngine → Approval → Executor boundary.
