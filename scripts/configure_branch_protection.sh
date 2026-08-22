#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Configure and verify Lumi V4 main-branch protection through the GitHub CLI.

Usage:
  scripts/configure_branch_protection.sh [--repository OWNER/REPO] [--branch BRANCH] [--evidence PATH] [--apply]

Default mode is a dry run. Nothing changes unless --apply is supplied.
When --evidence points at a Lumi 4.0.0 GA evidence JSON, verified governance
fields are updated only after GitHub confirms the protection policy is active.
The authenticated GitHub account must have repository administration permission.
EOF
}

REPOSITORY="${LUMI_GITHUB_REPOSITORY:-Baterzhop/LumiOrigin}"
BRANCH="main"
EVIDENCE=""
APPLY=0

while (($#)); do
  case "$1" in
    --repository)
      [[ $# -ge 2 ]] || { echo "--repository requires OWNER/REPO" >&2; exit 2; }
      REPOSITORY="$2"
      shift 2
      ;;
    --branch)
      [[ $# -ge 2 ]] || { echo "--branch requires a branch name" >&2; exit 2; }
      BRANCH="$2"
      shift 2
      ;;
    --evidence)
      [[ $# -ge 2 ]] || { echo "--evidence requires a JSON path" >&2; exit 2; }
      EVIDENCE="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid repository name: $REPOSITORY" >&2
  exit 2
fi
if [[ -z "$BRANCH" || "$BRANCH" == *$'\n'* || "$BRANCH" == *$'\r'* ]]; then
  echo "Invalid branch name" >&2
  exit 2
fi
if [[ -n "$EVIDENCE" && ! -f "$EVIDENCE" ]]; then
  echo "Evidence file not found: $EVIDENCE" >&2
  exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required." >&2
  exit 2
fi

gh auth status >/dev/null

CHECKS_JSON='[
  "core (ubuntu-latest, 3.12)",
  "core (macos-14, 3.12)",
  "macos-client",
  "macos-install-smoke",
  "macos-ga-orchestration-smoke"
]'

PAYLOAD="$(python3 - "$CHECKS_JSON" <<'PY'
import json, sys
contexts = json.loads(sys.argv[1])
print(json.dumps({
    "required_status_checks": {"strict": True, "contexts": contexts},
    "enforce_admins": False,
    "required_pull_request_reviews": {
        "dismiss_stale_reviews": True,
        "require_code_owner_reviews": False,
        "required_approving_review_count": 0,
        "require_last_push_approval": False,
    },
    "restrictions": None,
    "required_linear_history": False,
    "allow_force_pushes": False,
    "allow_deletions": False,
    "block_creations": False,
    "required_conversation_resolution": True,
    "lock_branch": False,
    "allow_fork_syncing": True,
}, separators=(",", ":")))
PY
)"

echo "Repository: $REPOSITORY"
echo "Branch:     $BRANCH"
echo "Required V4 CI contexts:"
printf '%s\n' "$CHECKS_JSON"
if [[ -n "$EVIDENCE" ]]; then
  echo "Evidence:   $EVIDENCE"
fi
echo

if [[ "$APPLY" -ne 1 ]]; then
  echo "DRY RUN — no repository setting and no evidence file was changed."
  echo "Re-run with --apply after reviewing the policy."
  exit 0
fi

echo "$PAYLOAD" | gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "repos/$REPOSITORY/branches/$BRANCH/protection" \
  --input - >/dev/null

PROTECTION="$(gh api \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "repos/$REPOSITORY/branches/$BRANCH/protection")"

python3 - "$PROTECTION" "$EVIDENCE" <<'PY'
import json
import os
from pathlib import Path
import sys

payload = json.loads(sys.argv[1])
evidence_path = Path(sys.argv[2]).expanduser() if len(sys.argv) > 2 and sys.argv[2] else None
checks = payload.get("required_status_checks") or {}
contexts = set(checks.get("contexts") or [])
pr = payload.get("required_pull_request_reviews")
force = payload.get("allow_force_pushes") or {}
delete = payload.get("allow_deletions") or {}
conversation = payload.get("required_conversation_resolution") or {}
expected = {
    "core (ubuntu-latest, 3.12)",
    "core (macos-14, 3.12)",
    "macos-client",
    "macos-install-smoke",
    "macos-ga-orchestration-smoke",
}
errors = []
if not expected.issubset(contexts):
    errors.append("required V4 CI contexts are incomplete")
if checks.get("strict") is not True:
    errors.append("required status checks are not strict")
if pr is None:
    errors.append("pull-request protection is missing")
if force.get("enabled") is True:
    errors.append("force pushes are still allowed")
if delete.get("enabled") is True:
    errors.append("branch deletion is still allowed")
if conversation.get("enabled") is not True:
    errors.append("conversation resolution is not required")
if errors:
    raise SystemExit("Protection verification failed: " + "; ".join(errors))

print("Branch protection applied and verified.")

if evidence_path is not None:
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    if not isinstance(evidence, dict) or evidence.get("schema_version") != 1 or evidence.get("version") != "4.0.0":
        raise SystemExit("Evidence file is not a Lumi 4.0.0 GA evidence document")
    governance = evidence.get("governance")
    if not isinstance(governance, dict):
        raise SystemExit("Evidence file governance object is missing")
    governance.update({
        "main_protected": True,
        "pull_requests_required": True,
        "v4_ci_required": True,
        "force_push_blocked": True,
        "deletion_blocked": True,
    })
    temporary = evidence_path.with_name(evidence_path.name + ".tmp")
    temporary.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    try:
        os.chmod(temporary, 0o600)
    except OSError:
        pass
    os.replace(temporary, evidence_path)
    print(f"Verified governance fields written to evidence: {evidence_path}")
PY
