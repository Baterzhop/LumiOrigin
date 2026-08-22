from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
ASSEMBLER = ROOT / "scripts" / "assemble_ga_evidence.py"
VALIDATOR = ROOT / "scripts" / "validate_ga_evidence.py"


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _valid_target(candidate: str = "a" * 40) -> dict:
    return {
        "schema_version": 1,
        "version": "4.0.0",
        "candidate_commit": candidate,
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


def _notary() -> dict:
    return {
        "version": "4.0.0",
        "timestamp_utc": "2026-08-22T09:00:00Z",
        "public": True,
        "notarization_ok": True,
        "codesign_ok": True,
        "notary_status": "Accepted",
        "stapler_ok": True,
        "gatekeeper_ok": True,
        "artifact_sha256": "b" * 64,
    }


def test_private_evidence_assembly_preserves_verified_target():
    assembler = _load(ASSEMBLER, "ga_assembler_private")
    validator = _load(VALIDATOR, "ga_validator_private")
    source = _valid_target()
    final = assembler.assemble(source, expected_candidate="a" * 40, validator=validator)
    assert final == source
    assert final is not source


def test_candidate_mismatch_fails_closed():
    assembler = _load(ASSEMBLER, "ga_assembler_mismatch")
    validator = _load(VALIDATOR, "ga_validator_mismatch")
    try:
        assembler.assemble(_valid_target(), expected_candidate="c" * 40, validator=validator)
    except assembler.AssemblyError as exc:
        assert "candidate_commit_mismatch" in str(exc)
    else:
        raise AssertionError("candidate mismatch must fail")


def test_unverified_governance_fails_closed():
    assembler = _load(ASSEMBLER, "ga_assembler_governance")
    validator = _load(VALIDATOR, "ga_validator_governance")
    source = _valid_target()
    source["governance"]["main_protected"] = False
    try:
        assembler.assemble(source, expected_candidate="a" * 40, validator=validator)
    except assembler.AssemblyError as exc:
        assert "governance_not_verified:main_protected" in str(exc)
    else:
        raise AssertionError("unverified governance must fail")


def test_public_assembly_requires_and_validates_notarization():
    assembler = _load(ASSEMBLER, "ga_assembler_public")
    validator = _load(VALIDATOR, "ga_validator_public")
    try:
        assembler.assemble(_valid_target(), expected_candidate="a" * 40, require_public=True, validator=validator)
    except assembler.AssemblyError as exc:
        assert "public_distribution_requires_notarization_fragment" in str(exc)
    else:
        raise AssertionError("public assembly without notary evidence must fail")

    final = assembler.assemble(
        _valid_target(),
        expected_candidate="a" * 40,
        notarization=_notary(),
        require_public=True,
        validator=validator,
    )
    assert final["distribution"]["public"] is True
    assert final["distribution"]["notary_status"] == "Accepted"
    assert final["distribution"]["artifact_sha256"] == "b" * 64


def test_unknown_notary_fields_are_rejected():
    assembler = _load(ASSEMBLER, "ga_assembler_unknown")
    validator = _load(VALIDATOR, "ga_validator_unknown")
    notary = _notary()
    notary["secret_or_unexpected"] = "x"
    try:
        assembler.assemble(
            _valid_target(),
            expected_candidate="a" * 40,
            notarization=notary,
            require_public=True,
            validator=validator,
        )
    except assembler.AssemblyError as exc:
        assert "notarization_unknown_fields" in str(exc)
    else:
        raise AssertionError("unknown notarization fields must fail")


def test_cli_writes_private_valid_evidence(tmp_path: Path):
    candidate = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.strip()
    target = tmp_path / "target.json"
    output = tmp_path / "final.json"
    target.write_text(json.dumps(_valid_target(candidate)), encoding="utf-8")

    result = subprocess.run(
        [sys.executable, str(ASSEMBLER), str(target), "--output", str(output)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    final = json.loads(output.read_text(encoding="utf-8"))
    assert final["candidate_commit"] == candidate
    assert stat.S_IMODE(output.stat().st_mode) == 0o600

    validated = subprocess.run(
        [sys.executable, str(VALIDATOR), str(output)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert validated.returncode == 0, validated.stdout + validated.stderr
