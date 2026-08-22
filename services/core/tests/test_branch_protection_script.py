from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess


def _root() -> Path:
    return Path(__file__).resolve().parents[3]


def _fake_gh(tmp_path: Path) -> Path:
    gh = tmp_path / "gh"
    gh.write_text(
        """#!/usr/bin/env python3
import json
import sys
args = sys.argv[1:]
if args[:2] == [\"auth\", \"status\"]:
    raise SystemExit(0)
if args and args[0] == \"api\":
    if \"--method\" in args:
        sys.stdin.read()
        raise SystemExit(0)
    print(json.dumps({
        \"required_status_checks\": {
            \"strict\": True,
            \"contexts\": [
                \"core (ubuntu-latest, 3.12)\",
                \"core (macos-14, 3.12)\",
                \"macos-client\",
                \"macos-install-smoke\",
                \"macos-ga-orchestration-smoke\",
            ],
        },
        \"required_pull_request_reviews\": {\"required_approving_review_count\": 0},
        \"allow_force_pushes\": {\"enabled\": False},
        \"allow_deletions\": {\"enabled\": False},
        \"required_conversation_resolution\": {\"enabled\": True},
    }))
    raise SystemExit(0)
raise SystemExit(2)
""",
        encoding="utf-8",
    )
    gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
    return gh


def test_branch_protection_configurator_is_syntax_valid_and_fail_closed():
    script = _root() / "scripts" / "configure_branch_protection.sh"
    assert script.is_file()

    subprocess.run(["bash", "-n", str(script)], check=True)
    content = script.read_text(encoding="utf-8")

    assert "APPLY=0" in content
    assert "--apply" in content
    assert "--evidence" in content
    assert '"allow_force_pushes": False' in content
    assert '"allow_deletions": False' in content
    assert '"required_conversation_resolution": True' in content
    assert "core (ubuntu-latest, 3.12)" in content
    assert "core (macos-14, 3.12)" in content
    assert "macos-client" in content
    assert "macos-install-smoke" in content
    assert "macos-ga-orchestration-smoke" in content
    assert "Branch protection applied and verified." in content
    assert '"main_protected": True' in content
    assert '"pull_requests_required": True' in content
    assert '"v4_ci_required": True' in content
    assert '"force_push_blocked": True' in content
    assert '"deletion_blocked": True' in content


def test_verified_protection_updates_only_governance_evidence(tmp_path: Path):
    script = _root() / "scripts" / "configure_branch_protection.sh"
    _fake_gh(tmp_path)
    evidence = tmp_path / "4.0.0-ga.json"
    payload = {
        "schema_version": 1,
        "version": "4.0.0",
        "candidate_commit": "a" * 40,
        "target_mac": {"ok": True},
        "governance": {
            "main_protected": False,
            "pull_requests_required": False,
            "v4_ci_required": False,
            "force_push_blocked": False,
            "deletion_blocked": False,
        },
        "distribution": {"public": False},
    }
    evidence.write_text(json.dumps(payload), encoding="utf-8")
    env = os.environ.copy()
    env["PATH"] = str(tmp_path) + os.pathsep + env.get("PATH", "")

    completed = subprocess.run(
        [
            "bash",
            str(script),
            "--repository",
            "example/lumi",
            "--evidence",
            str(evidence),
            "--apply",
        ],
        env=env,
        check=True,
        text=True,
        capture_output=True,
    )
    assert "Branch protection applied and verified." in completed.stdout
    assert "Verified governance fields written to evidence" in completed.stdout

    updated = json.loads(evidence.read_text(encoding="utf-8"))
    assert updated["candidate_commit"] == payload["candidate_commit"]
    assert updated["target_mac"] == payload["target_mac"]
    assert updated["distribution"] == payload["distribution"]
    assert updated["governance"] == {
        "main_protected": True,
        "pull_requests_required": True,
        "v4_ci_required": True,
        "force_push_blocked": True,
        "deletion_blocked": True,
    }
    assert stat.S_IMODE(evidence.stat().st_mode) == 0o600


def test_dry_run_never_changes_evidence(tmp_path: Path):
    script = _root() / "scripts" / "configure_branch_protection.sh"
    _fake_gh(tmp_path)
    evidence = tmp_path / "4.0.0-ga.json"
    original = {
        "schema_version": 1,
        "version": "4.0.0",
        "governance": {"main_protected": False},
    }
    evidence.write_text(json.dumps(original), encoding="utf-8")
    env = os.environ.copy()
    env["PATH"] = str(tmp_path) + os.pathsep + env.get("PATH", "")

    completed = subprocess.run(
        ["bash", str(script), "--repository", "example/lumi", "--evidence", str(evidence)],
        env=env,
        check=True,
        text=True,
        capture_output=True,
    )
    assert "DRY RUN" in completed.stdout
    assert json.loads(evidence.read_text(encoding="utf-8")) == original
