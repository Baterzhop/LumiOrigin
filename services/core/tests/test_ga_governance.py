from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
RULESET_SCRIPT = ROOT / "scripts" / "configure_main_ruleset.py"
COMPOSER = ROOT / "scripts" / "compose_ga_evidence.py"


def _load_ruleset_module():
    spec = importlib.util.spec_from_file_location("lumi_ga_ruleset", RULESET_SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _target() -> dict:
    return {
        "schema_version": 1,
        "version": "4.0.0",
        "candidate_commit": "a" * 40,
        "target_mac": {
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
    }


def _governance() -> dict:
    return {
        "governance": {
            "main_protected": True,
            "pull_requests_required": True,
            "v4_ci_required": True,
            "force_push_blocked": True,
            "deletion_blocked": True,
        }
    }


def test_desired_ruleset_meets_ga_governance_contract():
    module = _load_ruleset_module()
    ruleset = module.desired_ruleset()
    evidence, errors = module.evaluate_ruleset(ruleset)
    assert errors == []
    assert all(evidence.values())


def test_ruleset_verification_fails_when_required_check_is_missing():
    module = _load_ruleset_module()
    ruleset = module.desired_ruleset()
    checks = next(rule for rule in ruleset["rules"] if rule["type"] == "required_status_checks")
    checks["parameters"]["required_status_checks"] = checks["parameters"]["required_status_checks"][:-1]
    evidence, errors = module.evaluate_ruleset(ruleset)
    assert evidence["v4_ci_required"] is False
    assert any(error.startswith("missing_required_checks:") for error in errors)


def test_evidence_composer_produces_valid_local_ga_document(tmp_path):
    target = tmp_path / "target.json"
    governance = tmp_path / "governance.json"
    output = tmp_path / "4.0.0-ga.json"
    target.write_text(json.dumps(_target()), encoding="utf-8")
    governance.write_text(json.dumps(_governance()), encoding="utf-8")
    result = subprocess.run(
        [
            sys.executable,
            str(COMPOSER),
            "--target",
            str(target),
            "--governance",
            str(governance),
            "--output",
            str(output),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    payload = json.loads(output.read_text(encoding="utf-8"))
    assert payload["target_mac"]["ok"] is True
    assert payload["governance"]["main_protected"] is True
    assert payload["distribution"]["public"] is False


def test_evidence_composer_fails_closed_for_incomplete_governance(tmp_path):
    target = tmp_path / "target.json"
    governance = tmp_path / "governance.json"
    target.write_text(json.dumps(_target()), encoding="utf-8")
    bad = _governance()
    bad["governance"]["v4_ci_required"] = False
    governance.write_text(json.dumps(bad), encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(COMPOSER), "--target", str(target), "--governance", str(governance)],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 1
    assert "governance.v4_ci_required_must_be_true" in result.stderr


def test_governance_helper_scripts_compile():
    result = subprocess.run(
        [sys.executable, "-m", "py_compile", str(RULESET_SCRIPT), str(COMPOSER)],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
