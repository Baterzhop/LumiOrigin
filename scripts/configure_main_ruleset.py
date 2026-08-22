#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request, urlopen

API_VERSION = "2026-03-10"
RULESET_NAME = "Lumi V4 main release protection"
DEFAULT_REPOSITORY = "Baterzhop/LumiOrigin"
REQUIRED_CHECKS = (
    "core (ubuntu-latest, 3.12)",
    "core (macos-14, 3.12)",
    "macos-client",
    "macos-install-smoke",
    "macos-ga-orchestration-smoke",
)


def desired_ruleset() -> dict[str, Any]:
    return {
        "name": RULESET_NAME,
        "target": "branch",
        "enforcement": "active",
        "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
        "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {
                "type": "pull_request",
                "parameters": {
                    "allowed_merge_methods": ["merge", "squash", "rebase"],
                    "dismiss_stale_reviews_on_push": False,
                    "require_code_owner_review": False,
                    "require_last_push_approval": False,
                    "required_approving_review_count": 0,
                    "required_review_thread_resolution": False,
                },
            },
            {
                "type": "required_status_checks",
                "parameters": {
                    "do_not_enforce_on_create": False,
                    "required_status_checks": [{"context": context} for context in REQUIRED_CHECKS],
                    "strict_required_status_checks_policy": True,
                },
            },
        ],
    }


def evaluate_ruleset(ruleset: object) -> tuple[dict[str, bool], list[str]]:
    errors: list[str] = []
    if not isinstance(ruleset, dict):
        return {}, ["ruleset_not_object"]
    rules = ruleset.get("rules")
    if not isinstance(rules, list):
        return {}, ["rules_missing"]
    by_type = {
        str(rule.get("type")): rule
        for rule in rules
        if isinstance(rule, dict) and rule.get("type")
    }
    pull = by_type.get("pull_request")
    checks = by_type.get("required_status_checks")
    deletion = "deletion" in by_type
    non_fast_forward = "non_fast_forward" in by_type
    check_contexts: set[str] = set()
    strict = False
    if isinstance(checks, dict):
        parameters = checks.get("parameters")
        if isinstance(parameters, dict):
            strict = parameters.get("strict_required_status_checks_policy") is True
            values = parameters.get("required_status_checks")
            if isinstance(values, list):
                check_contexts = {
                    str(item.get("context"))
                    for item in values
                    if isinstance(item, dict) and item.get("context")
                }
    missing = sorted(set(REQUIRED_CHECKS) - check_contexts)
    if missing:
        errors.append("missing_required_checks:" + ",".join(missing))
    if ruleset.get("enforcement") != "active":
        errors.append("ruleset_not_active")
    conditions = ruleset.get("conditions")
    ref_names = conditions.get("ref_name") if isinstance(conditions, dict) else None
    includes = ref_names.get("include") if isinstance(ref_names, dict) else None
    if not isinstance(includes, list) or "~DEFAULT_BRANCH" not in includes:
        errors.append("default_branch_not_targeted")
    if pull is None:
        errors.append("pull_request_rule_missing")
    if not strict:
        errors.append("strict_status_checks_disabled")
    if not deletion:
        errors.append("deletion_rule_missing")
    if not non_fast_forward:
        errors.append("non_fast_forward_rule_missing")
    evidence = {
        "main_protected": not errors,
        "pull_requests_required": pull is not None,
        "v4_ci_required": not missing and strict,
        "force_push_blocked": non_fast_forward,
        "deletion_blocked": deletion,
    }
    return evidence, errors


def _request(method: str, url: str, token: str, payload: object | None = None) -> object:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = Request(
        url,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": API_VERSION,
            "User-Agent": "lumi-v4-ga-governance",
            "Content-Type": "application/json",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            body = response.read()
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"github_api_{exc.code}:{detail[:1000]}") from exc
    return json.loads(body) if body else None


def _token() -> str:
    value = os.getenv("GITHUB_ADMIN_TOKEN", "").strip() or os.getenv("GH_TOKEN", "").strip()
    if not value:
        raise RuntimeError("Set GITHUB_ADMIN_TOKEN (fine-grained repository Administration: write) or GH_TOKEN")
    return value


def _find_ruleset(repository: str, token: str) -> dict[str, Any] | None:
    items = _request("GET", f"https://api.github.com/repos/{repository}/rulesets?includes_parents=false", token)
    if not isinstance(items, list):
        raise RuntimeError("github_rulesets_response_not_array")
    for item in items:
        if isinstance(item, dict) and item.get("name") == RULESET_NAME:
            identifier = item.get("id")
            if identifier is None:
                raise RuntimeError("ruleset_id_missing")
            detail = _request("GET", f"https://api.github.com/repos/{repository}/rulesets/{identifier}", token)
            if not isinstance(detail, dict):
                raise RuntimeError("github_ruleset_detail_not_object")
            return detail
    return None


def configure(repository: str, token: str) -> dict[str, Any]:
    current = _find_ruleset(repository, token)
    payload = desired_ruleset()
    if current is None:
        created = _request("POST", f"https://api.github.com/repos/{repository}/rulesets", token, payload)
        if not isinstance(created, dict):
            raise RuntimeError("github_ruleset_create_not_object")
        return created
    identifier = current.get("id")
    updated = _request("PUT", f"https://api.github.com/repos/{repository}/rulesets/{identifier}", token, payload)
    if not isinstance(updated, dict):
        raise RuntimeError("github_ruleset_update_not_object")
    return updated


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Create/verify the Lumi V4 main-branch release ruleset.")
    parser.add_argument("--repository", default=DEFAULT_REPOSITORY)
    parser.add_argument("--apply", action="store_true", help="Create/update the ruleset. Without this flag, verify only.")
    parser.add_argument("--evidence-out", type=Path, help="Write non-secret governance evidence JSON.")
    args = parser.parse_args(argv)
    try:
        token = _token()
        ruleset = configure(args.repository, token) if args.apply else _find_ruleset(args.repository, token)
        if ruleset is None:
            raise RuntimeError(f"ruleset_not_found:{RULESET_NAME}")
        evidence, errors = evaluate_ruleset(ruleset)
        payload = {
            "ok": not errors,
            "repository": args.repository,
            "ruleset_id": ruleset.get("id"),
            "ruleset_name": RULESET_NAME,
            "verified_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "governance": evidence,
            "errors": errors,
        }
        if args.evidence_out:
            args.evidence_out.expanduser().parent.mkdir(parents=True, exist_ok=True)
            args.evidence_out.expanduser().write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0 if not errors else 1
    except Exception as exc:
        print(json.dumps({"ok": False, "error": f"{type(exc).__name__}:{exc}"}, indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
