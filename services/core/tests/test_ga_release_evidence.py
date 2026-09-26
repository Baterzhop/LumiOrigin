from __future__ import annotations

import asyncio
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / "scripts" / "validate_ga_evidence.py"
MAC_ACCEPTANCE = ROOT / "scripts" / "ga_acceptance_macos.py"


def _valid_payload() -> dict:
    return {
        "schema_version": 1,
        "version": "4.0.0",
        "candidate_commit": "a" * 40,
        "target_mac": {
            "environment": "physical_mac",
            "ok": True,
            "timestamp_utc": "2026-08-22T08:00:00Z",
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


def _run_validator(tmp_path: Path, payload: dict, *extra: str) -> subprocess.CompletedProcess[str]:
    evidence = tmp_path / "evidence.json"
    evidence.write_text(json.dumps(payload), encoding="utf-8")
    return subprocess.run(
        [sys.executable, str(VALIDATOR), str(evidence), *extra],
        text=True,
        capture_output=True,
        check=False,
    )


def _load_mac_acceptance_module():
    spec = importlib.util.spec_from_file_location("lumi_ga_acceptance_macos", MAC_ACCEPTANCE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_local_ga_evidence_accepts_verified_target_and_governance(tmp_path):
    result = _run_validator(tmp_path, _valid_payload())
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(result.stdout)["ok"] is True


def test_ga_evidence_fails_closed_when_target_gate_missing(tmp_path):
    payload = _valid_payload()
    payload["target_mac"]["restart_ok"] = False
    result = _run_validator(tmp_path, payload)
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert "target_mac.restart_ok_must_be_true" in report["errors"]


def test_public_distribution_requires_notarization_evidence(tmp_path):
    payload = _valid_payload()
    payload["distribution"]["public"] = True
    result = _run_validator(tmp_path, payload, "--public")
    assert result.returncode == 1
    assert "distribution.notarization_ok_must_be_true" in json.loads(result.stdout)["errors"]


def test_public_distribution_accepts_complete_notarization_evidence(tmp_path):
    payload = _valid_payload()
    payload["distribution"].update(
        {
            "public": True,
            "notarization_ok": True,
            "codesign_ok": True,
            "notary_status": "Accepted",
            "stapler_ok": True,
            "gatekeeper_ok": True,
            "artifact_sha256": "b" * 64,
            "source_commit": "a" * 40,
        }
    )
    result = _run_validator(tmp_path, payload, "--public")
    assert result.returncode == 0, result.stdout + result.stderr


def test_ga_helper_scripts_compile():
    result = subprocess.run(
        [sys.executable, "-m", "py_compile", str(VALIDATOR), str(MAC_ACCEPTANCE)],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_ga_tool_boundary_helper_executes_real_task_runtime(tmp_path):
    module = _load_mac_acceptance_module()
    read_ok, write_ok = asyncio.run(module._verify_tool_boundary(tmp_path))
    assert read_ok is True
    assert write_ok is True


def test_hosted_ci_evidence_cannot_satisfy_physical_gate(tmp_path):
    payload = _valid_payload()
    payload["target_mac"]["environment"] = "hosted_ci"
    result = _run_validator(tmp_path, payload)
    assert result.returncode == 1
    assert "target_mac.environment_must_be_physical_mac" in result.stdout


def test_public_distribution_cannot_omit_source_commit(tmp_path):
    payload = _valid_payload()
    payload["distribution"].update(public=True, notarization_ok=True, codesign_ok=True,
                                   notary_status="Accepted", stapler_ok=True, gatekeeper_ok=True,
                                   artifact_sha256="b" * 64)
    result = _run_validator(tmp_path, payload)
    assert result.returncode == 1
    assert "distribution.source_commit_invalid" in result.stdout


def test_physical_probe_rejects_dirty_candidate(tmp_path):
    module = _load_mac_acceptance_module()
    subprocess.run(["git", "init", str(tmp_path)], check=True, capture_output=True)
    (tmp_path / "uncommitted.py").write_text("changed = True\n")
    try:
        module._candidate_commit(tmp_path)
    except RuntimeError as exc:
        assert "clean_candidate_checkout" in str(exc)
    else:
        raise AssertionError("Uncommitted source must never be labeled with a candidate SHA")
