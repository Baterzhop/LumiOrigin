#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import tomllib

from validate_ga_evidence import validate

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
INIT_VERSION_RE = re.compile(r"__version__\s*=\s*[\"']([^\"']+)[\"']")
ALLOWED_RELEASE_FILES = {
    "CHANGELOG.md",
    "README.md",
    "RELEASE_CHECKLIST.md",
    "docs/release.md",
    "services/core/pyproject.toml",
    "services/core/src/lumi_core/__init__.py",
    "release-evidence/4.0.0-ga.json",
}


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        capture_output=True,
        check=check,
    )


def _show(repo: Path, ref: str, path: str) -> str:
    return _git(repo, "show", f"{ref}:{path}").stdout


def _project_version_at(repo: Path, ref: str) -> str:
    payload = tomllib.loads(_show(repo, ref, "services/core/pyproject.toml"))
    return str(payload["project"]["version"]).strip()


def _init_version_at(repo: Path, ref: str) -> str:
    text = _show(repo, ref, "services/core/src/lumi_core/__init__.py")
    match = INIT_VERSION_RE.search(text)
    if not match:
        raise SystemExit(f"Could not resolve lumi_core.__version__ at {ref}")
    return match.group(1)


def verify(repo: Path, evidence: dict, release_ref: str) -> list[str]:
    errors = validate(evidence)
    if errors:
        return [f"evidence:{error}" for error in errors]

    candidate = evidence.get("candidate_commit")
    if not isinstance(candidate, str) or not SHA_RE.fullmatch(candidate):
        return ["candidate_commit_invalid"]

    if _git(repo, "cat-file", "-e", f"{candidate}^{{commit}}", check=False).returncode != 0:
        return ["candidate_commit_not_found_in_repository"]
    if _git(repo, "cat-file", "-e", f"{release_ref}^{{commit}}", check=False).returncode != 0:
        return ["release_ref_not_found_in_repository"]
    if _git(repo, "merge-base", "--is-ancestor", candidate, release_ref, check=False).returncode != 0:
        return ["candidate_commit_is_not_ancestor_of_release"]

    candidate_project = _project_version_at(repo, candidate)
    candidate_init = _init_version_at(repo, candidate)
    target = evidence.get("target_mac") or {}
    target_core = str(target.get("core_version") or "").strip()
    target_app = str(target.get("app_version") or "").strip()
    if candidate_project != candidate_init:
        errors.append("candidate_project_and_runtime_versions_differ")
    if target_core != candidate_project:
        errors.append("target_mac.core_version_does_not_match_candidate")
    if target_app != candidate_project:
        errors.append("target_mac.app_version_does_not_match_candidate")

    release_project = _project_version_at(repo, release_ref)
    release_init = _init_version_at(repo, release_ref)
    if release_project != "4.0.0":
        errors.append("release_project_version_must_be_4.0.0")
    if release_init != "4.0.0":
        errors.append("release_runtime_version_must_be_4.0.0")

    changed = {
        line.strip()
        for line in _git(repo, "diff", "--name-only", f"{candidate}..{release_ref}").stdout.splitlines()
        if line.strip()
    }
    forbidden = sorted(changed - ALLOWED_RELEASE_FILES)
    if forbidden:
        errors.append("runtime_or_unapproved_files_changed_after_candidate:" + ",".join(forbidden))
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Prove that Lumi 4.0.0 is a metadata-only promotion of the physically tested GA candidate."
    )
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--release-ref", default="HEAD")
    args = parser.parse_args(argv)

    try:
        evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    except Exception as exc:
        print(json.dumps({"ok": False, "errors": [f"evidence_read_failed:{type(exc).__name__}"]}, indent=2))
        return 1
    if not isinstance(evidence, dict):
        print(json.dumps({"ok": False, "errors": ["evidence_must_be_json_object"]}, indent=2))
        return 1

    errors = verify(args.repo.expanduser().resolve(), evidence, args.release_ref)
    print(json.dumps({"ok": not errors, "errors": errors}, indent=2, sort_keys=True))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
