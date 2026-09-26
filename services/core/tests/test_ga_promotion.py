from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import pytest


ROOT = Path(__file__).resolve().parents[3]
COMPOSER = ROOT / "scripts" / "compose_ga_evidence.py"
PROMOTION = ROOT / "scripts" / "verify_ga_promotion.py"


def _target(candidate: str = "a" * 40) -> dict:
    return {
        "schema_version": 1,
        "version": "4.0.0",
        "candidate_commit": candidate,
        "target_mac": {
            "environment": "physical_mac",
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


def _notarization(source: str) -> dict:
    return {
        "source_commit": source,
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
    repo, candidate = _promotion_repo(tmp_path)
    _commit_release(repo, candidate)
    target = tmp_path / "target.json"
    output = tmp_path / "ga.json"
    target.write_text(json.dumps(_target(candidate)), encoding="utf-8")
    args = (str(COMPOSER), str(target), "--repo", str(repo), "--expected-candidate", candidate, "--output", str(output))
    result = _run(*args)
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(output.read_text(encoding="utf-8"))
    assert payload["candidate_commit"] == candidate
    assert payload["distribution"]["public"] is False
    original = output.read_bytes()
    target.write_text(json.dumps(_target(candidate), sort_keys=True, indent=4), encoding="utf-8")
    assert _run(*args).returncode == 0
    assert output.read_bytes() == original
    assert not list(tmp_path.glob("ga.json.*.tmp"))


def test_compose_public_ga_evidence_requires_verified_notarization(tmp_path: Path):
    repo, candidate = _promotion_repo(tmp_path)
    _commit_release(repo, candidate)
    target = tmp_path / "target.json"
    notary = tmp_path / "notary.json"
    output = tmp_path / "ga.json"
    target.write_text(json.dumps(_target(candidate)), encoding="utf-8")
    source = _git(repo, "rev-parse", "HEAD")
    notary.write_text(json.dumps(_notarization(source)), encoding="utf-8")
    result = _run(
        str(COMPOSER), str(target), "--notarization", str(notary), "--public", "--output", str(output),
        "--repo", str(repo), "--expected-candidate", candidate,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    distribution = json.loads(output.read_text(encoding="utf-8"))["distribution"]
    assert distribution["public"] is True
    assert distribution["notary_status"] == "Accepted"
    assert distribution["artifact_sha256"] == "b" * 64
    assert distribution["source_commit"] == source
    (repo / "release-evidence/4.0.0-ga.json").write_bytes(output.read_bytes())
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "public evidence")
    assert _promotion_result(repo).returncode == 0


def test_compose_fails_closed_for_missing_governance(tmp_path: Path):
    payload = _target()
    payload["governance"]["main_protected"] = False
    target = tmp_path / "target.json"
    target.write_text(json.dumps(payload), encoding="utf-8")
    result = _run(str(COMPOSER), str(target), "--expected-candidate", "a" * 40, "--output", str(tmp_path / "ga.json"))
    assert result.returncode == 1
    assert "governance.main_protected_must_be_true" in result.stderr


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True, check=True)
    return completed.stdout.strip()


def _promotion_result(repo: Path, evidence: Path | None = None) -> subprocess.CompletedProcess[str]:
    return _run(str(PROMOTION), str(evidence or repo / "release-evidence/4.0.0-ga.json"),
                "--repo", str(repo), "--release-ref", "HEAD")


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
    _git(repo, "config", "core.autocrlf", "false")
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

@pytest.mark.parametrize("path,extra", [
    ("services/core/pyproject.toml", '\n[project.entry-points."hidden"]\nrun = "evil:main"\n'),
    ("services/core/src/lumi_core/__init__.py", '\nprint("unexpected-runtime-code")\n'),
    ("services/core/requirements.lock", "new-dependency==1\n"),
    (".github/workflows/release.yml", "changed workflow\n"),
    ('odd файл.txt', "path requiring Git quoting\n"),
])
def test_promotion_rejects_hidden_runtime_and_dependency_changes(tmp_path, path, extra):
    repo, candidate = _promotion_repo(tmp_path)
    _commit_release(repo, candidate)
    changed = repo / path
    changed.parent.mkdir(parents=True, exist_ok=True)
    with changed.open("a", encoding="utf-8") as stream:
        stream.write(extra)
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "unapproved change")
    result = _promotion_result(repo)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "changed_after_candidate" in result.stdout


def test_promotion_rejects_metadata_mode_change(tmp_path):
    repo, candidate = _promotion_repo(tmp_path)
    _commit_release(repo, candidate)
    _git(repo, "update-index", "--chmod=+x", "services/core/pyproject.toml")
    _git(repo, "commit", "-m", "change file mode")
    result = _promotion_result(repo)
    assert result.returncode == 1
    assert "release_metadata_not_regular_file" in result.stdout


@pytest.mark.parametrize("change", ["missing", "unrelated", "wrong_version", "wrong_app", "different_evidence"])
def test_promotion_rejects_incorrect_candidate_provenance(tmp_path, change):
    repo, candidate = _promotion_repo(tmp_path)
    if change == "unrelated":
        tree = _git(repo, "rev-parse", "HEAD^{tree}")
        candidate = _git(repo, "commit-tree", tree, "-m", "unrelated root")
    _commit_release(repo, candidate)
    evidence = repo / "release-evidence/4.0.0-ga.json"
    payload = json.loads(evidence.read_text())
    if change == "missing":
        payload["candidate_commit"] = "a" * 40
    elif change == "wrong_version":
        payload["target_mac"]["core_version"] = "4.0.0rc4"
    elif change == "wrong_app":
        payload["target_mac"]["app_version"] = "4.0.0rc4"
    elif change == "different_evidence":
        payload["target_mac"]["model"] = "another-model"
    external = tmp_path / "supplied.json"
    external.write_text(json.dumps(payload))
    result = _promotion_result(repo, external)
    assert result.returncode == 1, result.stdout + result.stderr


@pytest.mark.parametrize("fault", ["candidate", "dirty", "runtime", "hosted", "governance", "downgrade", "notary_source"])
def test_composer_fails_without_overwriting_existing_output(tmp_path, fault):
    repo, candidate = _promotion_repo(tmp_path)
    _commit_release(repo, candidate, mutate_runtime=fault == "runtime")
    payload = _target(candidate)
    if fault == "hosted":
        payload["target_mac"]["environment"] = "hosted_ci"
    if fault == "governance":
        payload["governance"]["main_protected"] = False
    if fault == "downgrade":
        payload["distribution"]["public"] = True
    if fault == "dirty":
        (repo / "uncommitted.py").write_text("changed = True\n")
    target, output = tmp_path / "target.json", tmp_path / "output.json"
    target.write_text(json.dumps(payload))
    output.write_bytes(b"existing evidence must survive\n")
    extra = []
    if fault == "notary_source":
        notary = tmp_path / "notary.json"
        notary.write_text(json.dumps(_notarization("b" * 40)))
        extra = ["--public", "--notarization", str(notary)]
    result = _run(str(COMPOSER), str(target), "--repo", str(repo), "--expected-candidate",
                  "a" * 40 if fault == "candidate" else candidate, "--output", str(output), *extra)
    assert result.returncode == 1, result.stdout + result.stderr
    assert output.read_bytes() == b"existing evidence must survive\n"


def test_notarized_source_with_runtime_drift_cannot_be_used_even_if_later_reverted(tmp_path):
    repo, candidate = _promotion_repo(tmp_path)
    _commit_release(repo, candidate, mutate_runtime=True)
    source = _git(repo, "rev-parse", "HEAD")
    _git(repo, "checkout", candidate, "--", "services/core/src/lumi_core/runtime.py")
    payload = _target(candidate)
    payload["distribution"] = {k: v for k, v in _notarization(source).items() if k not in {"version", "timestamp_utc"}}
    (repo / "release-evidence/4.0.0-ga.json").write_text(json.dumps(payload))
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "revert runtime and attach wrong notarization")
    result = _promotion_result(repo)
    assert result.returncode == 1
    assert "notarization:runtime_or_unapproved_files_changed_after_candidate" in result.stdout


def test_final_version_candidate_can_be_promoted_with_evidence_only(tmp_path):
    repo, _ = _promotion_repo(tmp_path)
    _write_version(repo, "4.0.0")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "final-version candidate")
    candidate = _git(repo, "rev-parse", "HEAD")
    _commit_release(repo, candidate)
    evidence = repo / "release-evidence/4.0.0-ga.json"
    payload = json.loads(evidence.read_text())
    payload["target_mac"].update(app_version="4.0.0", core_version="4.0.0")
    evidence.write_text(json.dumps(payload))
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "record final candidate version")
    assert _promotion_result(repo).returncode == 0
