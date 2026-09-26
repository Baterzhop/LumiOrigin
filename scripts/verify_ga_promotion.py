#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess

from lumi_version import project_version_from_text
from validate_ga_evidence import validate

CANDIDATE_VERSION_RE = re.compile(r"^4\.0\.0(?:rc[1-9][0-9]*)?$")
PROJECT = "services/core/pyproject.toml"
INIT = "services/core/src/lumi_core/__init__.py"
EVIDENCE = "release-evidence/4.0.0-ga.json"
RELEASE_DOCUMENTS = {"CHANGELOG.md", "README.md", "RELEASE_CHECKLIST.md", "docs/release.md"}
ALLOWED_RELEASE_FILES = RELEASE_DOCUMENTS | {PROJECT, INIT, EVIDENCE}
INIT_VERSION_RE = re.compile(r'''(?m)^__version__[ \t]*=[ \t]*(["'])([^"'\r\n]+)\1[ \t]*(?:#.*)?\r?$''')
PROJECT_VERSION_RE = re.compile(r'''(?m)^version[ \t]*=[ \t]*(["'])([^"'\r\n]+)\1[ \t]*(?:#.*)?\r?$''')


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(repo), *args], text=True, encoding="utf-8",
                          capture_output=True, check=check)


def _show(repo: Path, ref: str, path: str) -> str:
    # Preserve blob line endings: only the version value may differ.
    return subprocess.run(["git", "-C", str(repo), "show", f"{ref}:{path}"],
                          capture_output=True, check=True).stdout.decode("utf-8")


def _version_marker(text: str, path: str) -> re.Match[str]:
    start, end = 0, len(text)
    pattern = INIT_VERSION_RE
    if path == PROJECT:
        sections = list(re.finditer(r"(?m)^\[([^\r\n]+)\][ \t]*(?:#.*)?\r?$", text))
        project = [i for i, section in enumerate(sections) if section.group(1) == "project"]
        if len(project) != 1:
            raise ValueError("canonical_project_section_missing_or_ambiguous")
        i = project[0]
        start = sections[i].end()
        end = sections[i + 1].start() if i + 1 < len(sections) else len(text)
        pattern = PROJECT_VERSION_RE
    matches = list(pattern.finditer(text, start, end))
    if len(matches) != 1:
        raise ValueError(f"version_marker_missing_or_ambiguous:{path}")
    return matches[0]


def _normalized_version(text: str, path: str, version: str) -> str:
    marker = _version_marker(text, path)
    if marker.group(2) != version:
        raise ValueError(f"version_marker_mismatch:{path}")
    return text[:marker.start(2)] + "<release-version>" + text[marker.end(2):]


def _versions(repo: Path, ref: str) -> tuple[str, str]:
    project = project_version_from_text(_show(repo, ref, PROJECT))
    runtime = _version_marker(_show(repo, ref, INIT), INIT).group(2)
    return project, runtime


def _tree(repo: Path, ref: str) -> dict[str, tuple[str, str, str]]:
    result = {}
    for entry in _git(repo, "ls-tree", "-r", "-z", ref).stdout.split("\0"):
        if entry:
            metadata, path = entry.split("\t", 1)
            mode, kind, sha = metadata.split()
            result[path] = (mode, kind, sha)
    return result


def _delta_errors(repo: Path, candidate: str, release: str) -> list[str]:
    before, after = _tree(repo, candidate), _tree(repo, release)
    changed = {path for path in before.keys() | after.keys() if before.get(path) != after.get(path)}
    errors = []
    forbidden = sorted(changed - ALLOWED_RELEASE_FILES)
    if forbidden:
        errors.append("runtime_or_unapproved_files_changed_after_candidate:" + ",".join(forbidden))
    for path in sorted(changed & ALLOWED_RELEASE_FILES):
        # A metadata path cannot hide a symlink, executable, submodule or mode change.
        if any(tree.get(path, ("100644", "blob", ""))[:2] != ("100644", "blob")
               for tree in (before, after)):
            errors.append(f"release_metadata_not_regular_file:{path}")
        if path in (PROJECT, INIT):
            old, new = _show(repo, candidate, path), _show(repo, release, path)
            old_version = _versions(repo, candidate)[0]
            new_version = _versions(repo, release)[0]
            if _normalized_version(old, path, old_version) != _normalized_version(new, path, new_version):
                errors.append(f"non_version_content_changed_after_candidate:{path}")
    return errors


def _verify(repo: Path, evidence: dict, release_ref: str, *, require_committed_evidence: bool) -> list[str]:
    errors = validate(evidence)
    if errors:
        return [f"evidence:{error}" for error in errors]
    candidate = evidence["candidate_commit"]
    if _git(repo, "cat-file", "-t", candidate, check=False).stdout.strip() != "commit":
        return ["candidate_commit_not_found_in_repository"]
    resolved = _git(repo, "rev-parse", "--verify", "--end-of-options", f"{release_ref}^{{commit}}", check=False)
    if resolved.returncode:
        return ["release_ref_not_found_in_repository"]
    release = resolved.stdout.strip()
    if _git(repo, "merge-base", "--is-ancestor", candidate, release, check=False).returncode:
        return ["candidate_commit_is_not_ancestor_of_release"]

    candidate_project, candidate_init = _versions(repo, candidate)
    if not CANDIDATE_VERSION_RE.fullmatch(candidate_project):
        errors.append("candidate_version_must_be_4.0.0_or_its_rc")
    if candidate_project != candidate_init:
        errors.append("candidate_project_and_runtime_versions_differ")
    for component in ("core", "app"):
        if evidence["target_mac"].get(f"{component}_version") != candidate_project:
            errors.append(f"target_mac.{component}_version_does_not_match_candidate")

    release_project, release_init = _versions(repo, release)
    if release_project != "4.0.0":
        errors.append("release_project_version_must_be_4.0.0")
    if release_init != "4.0.0":
        errors.append("release_runtime_version_must_be_4.0.0")
    errors.extend(_delta_errors(repo, candidate, release))

    if evidence["distribution"]["public"]:
        source = evidence["distribution"]["source_commit"]
        if _git(repo, "cat-file", "-t", source, check=False).stdout.strip() != "commit":
            errors.append("notarization_source_commit_not_found_in_repository")
        elif _git(repo, "merge-base", "--is-ancestor", candidate, source, check=False).returncode:
            errors.append("notarization_source_is_not_descendant_of_candidate")
        elif _git(repo, "merge-base", "--is-ancestor", source, release, check=False).returncode:
            errors.append("notarization_source_is_not_ancestor_of_release")
        else:
            if _versions(repo, source) != ("4.0.0", "4.0.0"):
                errors.append("notarization_source_version_must_be_4.0.0")
            errors.extend(f"notarization:{error}" for error in _delta_errors(repo, source, release))

    if require_committed_evidence:
        entry = _tree(repo, release).get(EVIDENCE)
        if not entry or entry[:2] != ("100644", "blob"):
            errors.append("release_evidence_must_be_committed_regular_file")
        elif json.loads(_show(repo, release, EVIDENCE)) != evidence:
            errors.append("supplied_evidence_does_not_match_release_commit")
    return errors


def verify(repo: Path, evidence: dict, release_ref: str, *, require_committed_evidence: bool = True) -> list[str]:
    try:
        return _verify(repo, evidence, release_ref, require_committed_evidence=require_committed_evidence)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError, SystemExit) as exc:
        return [f"provenance_read_failed:{type(exc).__name__}"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Prove Lumi 4.0.0 preserves the physically tested candidate, allowing only exact version-value and release-document edits.")
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--release-ref", default="HEAD")
    args = parser.parse_args(argv)
    try:
        evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        errors = [f"evidence_read_failed:{type(exc).__name__}"]
    else:
        errors = verify(args.repo.expanduser().resolve(), evidence, args.release_ref)
    print(json.dumps({"ok": not errors, "errors": errors}, indent=2, sort_keys=True))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
