#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import sys

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def _require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def validate(payload: object, *, require_public_distribution: bool = False) -> list[str]:
    errors: list[str] = []
    if not isinstance(payload, dict):
        return ["evidence_must_be_json_object"]

    _require(payload.get("schema_version") == 1, "schema_version_must_be_1", errors)
    _require(payload.get("version") == "4.0.0", "version_must_be_4.0.0", errors)
    commit = payload.get("candidate_commit")
    _require(isinstance(commit, str) and bool(SHA_RE.fullmatch(commit)), "candidate_commit_must_be_full_sha", errors)

    target = payload.get("target_mac")
    _require(isinstance(target, dict), "target_mac_missing", errors)
    if isinstance(target, dict):
        for key in (
            "ok",
            "real_model_ok",
            "fallback_false",
            "restart_ok",
            "durable_memory_ok",
            "grounded_citation_ok",
            "read_tool_ok",
            "approval_gated_write_ok",
            "backup_restore_copy_ok",
            "shutdown_ownership_ok",
        ):
            _require(target.get(key) is True, f"target_mac.{key}_must_be_true", errors)
        _require(bool(str(target.get("provider") or "").strip()), "target_mac.provider_required", errors)
        _require(bool(str(target.get("model") or "").strip()), "target_mac.model_required", errors)
        _require(bool(str(target.get("macos_version") or "").strip()), "target_mac.macos_version_required", errors)
        _require(bool(str(target.get("core_version") or "").strip()), "target_mac.core_version_required", errors)
        timestamp = target.get("timestamp_utc")
        if isinstance(timestamp, str):
            try:
                datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
            except ValueError:
                errors.append("target_mac.timestamp_utc_invalid")
        else:
            errors.append("target_mac.timestamp_utc_required")

    governance = payload.get("governance")
    _require(isinstance(governance, dict), "governance_missing", errors)
    if isinstance(governance, dict):
        for key in ("main_protected", "pull_requests_required", "v4_ci_required", "force_push_blocked", "deletion_blocked"):
            _require(governance.get(key) is True, f"governance.{key}_must_be_true", errors)

    distribution = payload.get("distribution")
    _require(isinstance(distribution, dict), "distribution_missing", errors)
    if isinstance(distribution, dict):
        public = distribution.get("public") is True
        if require_public_distribution:
            _require(public, "distribution.public_must_be_true", errors)
        if public or require_public_distribution:
            for key in ("notarization_ok", "codesign_ok", "stapler_ok", "gatekeeper_ok"):
                _require(distribution.get(key) is True, f"distribution.{key}_must_be_true", errors)
            _require(distribution.get("notary_status") == "Accepted", "distribution.notary_status_must_be_Accepted", errors)
            checksum = distribution.get("artifact_sha256")
            _require(isinstance(checksum, str) and bool(SHA256_RE.fullmatch(checksum)), "distribution.artifact_sha256_invalid", errors)

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate Lumi V4 GA evidence before final release.")
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--public", action="store_true", help="Require Developer-ID/notarization evidence for public distribution")
    args = parser.parse_args(argv)
    try:
        payload = json.loads(args.evidence.read_text(encoding="utf-8"))
    except Exception as exc:
        print(json.dumps({"ok": False, "errors": [f"evidence_read_failed:{type(exc).__name__}"]}, indent=2))
        return 1
    errors = validate(payload, require_public_distribution=args.public)
    print(json.dumps({"ok": not errors, "errors": errors}, indent=2, sort_keys=True))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
