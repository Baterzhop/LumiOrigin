from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
COMPOSER = ROOT / "scripts" / "compose_ga_evidence.py"
PROMOTION = ROOT / "scripts" / "verify_ga_promotion.py"


def _target(candidate: str = "a" * 40) -> dict:
    return {
        "schema_version": 1,
        "version": "4.0.0",
        "candidate_commit": candidate,
        "target_mac": {
            "ok": True,
            "timestamp_utc": "2026-08-22T19:00:00Z",
            "macos_version": "15.6",
            "app_version": "4.0.0rc5",
            "core_version": "4.0.0rc5",
            "provider": "ollama",
            "model": "qwen3:8b",
            "real_model_ok": True,
            "fallback_false": True,
            "restart_ok": True,
            "durable_memory_ok": True,
            "grounded_citation_ok": True,
            "read_tool_ok": True,
            "approval_gated_write_ok": True,
            "backup_restore_copy_ok": True,
            "shutdown_ownership_ok": True,
        },
        "governance": {
            "main_protected": True,
            "pull_requests_required": True,
            "v4_ci_required": True,
            "force_push_blocked": True,
            "deletion_blocked": True,
        },
        "distribution": {
            "public": False,
            "notarization_ok": False,
            "codesign_ok": False,
            "notary_status": "NotRun",
            "stapler_ok": False,
            "gatekeeper_ok": False,
            "artifact_sha256": "",
        },
    }


def _notarization() -> dict:
    return {
        "version": "4.0.0",
        "timestamp_utc": "2026-08-22T19:10:00Z",
        "public": True,
        "notarization_ok": True,
        "codesign_ok": True,
        "notary_status": "Accepted",
        "stapler_ok": True,
        "gatekeeper_ok": True,
        "artifact_sha256": "b" * 64,
    }


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, *args], text=True, capture_output=True, check=False)


def test_compose_local_ga_evidence_without_manual_json_editing(tmp_path: Path):
    target = tmp_path / "target.json"
    output = tmp_path / "ga.json"
    target.write_text(json.dumps(_target()), encoding="utf-8")
    result = _run(str(COMPOSER), str(target), "--output", str(output))
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(output.read_text(encoding="utf-8"))
    assert payload["candidate_commit"] == "a" * 40
    assert payload["distribution"]["public"] is False


def test_compose_public_ga_evidence_requires_verified_notarization(tmp_path: Path):
    target = tmp_path / "target.json"
    notary = tmp_path / "notary.json"
    output = tmp_path / "ga.json"
    target.write_text(json.dumps(_target()), encoding="utf-8")
    notary.write_text(json.dumps(_notarization()), encoding="utf-8")
    result = _run(
        str(COMPOSER), str(target), "--notarization", str(notary), "--public", "--output", str(output)
    )
    assert result.returncode == 0, result.stdout + result.stderr
    distribution = json.loads(output.read_text(encoding="utf-8"))["distribution"]
    assert distribution["public"] is True
    assert distribution["notary_status"] == "Accepted"
    assert distribution["artifact_sha256"] == "b" * 64


def test_compose_fails_closed_for_missing_governance(tmp_path: Path):
    payload = _target()
    payload["governance"]["main_protected"] = False
    target = tmp_path / "target.json"
    target.write_text(json.dumps(payload), encoding="utf-8")
    result = _run(str(COMPOSER), str(target), "--output", str(tmp_path / "ga.json"))
    assert result.returncode == 1
    assert "governance.main_protected_must_be_true" in result.stderr


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True, check=True)
    return completed.stdout.strip()


def _write_version(repo: Path, version: str) -> None:
    pyproject = repo / "services/core/pyproject.toml"
    init = repo / "services/core/src/lumi_core/__init__.py"
    pyproject.parent.mkdir(parents=True, exist_ok=True)
    init.parent.mkdir(parents=True, exist_ok=True)
    pyproject.write_text(f'[project]\nname = "lumi-core"\nversion = "{version}"\n', encoding="utf-8")
    init.write_text(f'__version__ = "{version}"\n', encoding="utf-8")


def _promotion_repo(tmp_path: Path) -> tuple[Path, str]:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")
    _git(repo, "config", "user.email", "lumi-ci@example.invalid")
    _git(repo, "config", "user.name", "Lumi CI")
    _write_version(repo, "4.0.0rc5")
    runtime = repo / "services/core/src/lumi_core/runtime.py"
    runtime.write_text("RUNTIME = 'candidate'\n", encoding="utf-8")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "candidate")
    return repo, _git(repo, "rev-parse", "HEAD")


def _commit_release(repo: Path, candidate: str, *, mutate_runtime: bool = False) -> None:
    _write_version(repo, "4.0.0")
    if mutate_runtime:
        (repo / "services/core/src/lumi_core/runtime.py").write_text("RUNTIME = 'changed-after-acceptance'\n", encoding="utf-8")
    evidence = _target(candidate)
    evidence_path = repo / "release-evidence/4.0.0-ga.json"
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "promote 4.0.0")


def test_ga_promotion_accepts_metadata_only_release_delta(tmp_path: Path):
    repo, candidate = _promotion_repo(tmp_path)
    _commit_release(repo, candidate)
    result = _run(
        str(PROMOTION), str(repo / "release-evidence/4.0.0-ga.json"), "--repo", str(repo), "--release-ref", "HEAD"
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(result.stdout)["ok"] is True


def test_ga_promotion_rejects_runtime_change_after_physical_candidate(tmp_path: Path):
    repo, candidate = _promotion_repo(tmp_path)
    _commit_release(repo, candidate, mutate_runtime=True)
    result = _run(
        str(PROMOTION), str(repo / "release-evidence/4.0.0-ga.json"), "--repo", str(repo), "--release-ref", "HEAD"
    )
    assert result.returncode == 1
    errors = json.loads(result.stdout)["errors"]
    assert any(error.startswith("runtime_or_unapproved_files_changed_after_candidate:") for error in errors)
