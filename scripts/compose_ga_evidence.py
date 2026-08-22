#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re

from validate_ga_evidence import validate

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def _load(path: Path) -> dict:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Could not read JSON evidence {path}: {type(exc).__name__}: {exc}") from exc
    if not isinstance(payload, dict):
        raise SystemExit(f"Evidence must be a JSON object: {path}")
    return payload


def _notarization_distribution(payload: dict) -> dict:
    required_true = ("public", "notarization_ok", "codesign_ok", "stapler_ok", "gatekeeper_ok")
    errors: list[str] = []
    if payload.get("version") != "4.0.0":
        errors.append("notarization.version_must_be_4.0.0")
    for key in required_true:
        if payload.get(key) is not True:
            errors.append(f"notarization.{key}_must_be_true")
    if payload.get("notary_status") != "Accepted":
        errors.append("notarization.notary_status_must_be_Accepted")
    checksum = payload.get("artifact_sha256")
    if not isinstance(checksum, str) or not SHA256_RE.fullmatch(checksum):
        errors.append("notarization.artifact_sha256_invalid")
    if errors:
        raise SystemExit("Invalid notarization evidence: " + ", ".join(errors))
    return {
        "public": True,
        "notarization_ok": True,
        "codesign_ok": True,
        "notary_status": "Accepted",
        "stapler_ok": True,
        "gatekeeper_ok": True,
        "artifact_sha256": checksum,
    }


def compose(target: dict, *, notarization: dict | None = None, public: bool = False) -> dict:
    payload = json.loads(json.dumps(target))
    if payload.get("schema_version") != 1 or payload.get("version") != "4.0.0":
        raise SystemExit("Target evidence is not a Lumi 4.0.0 schema_version=1 document")

    if public:
        if notarization is None:
            raise SystemExit("--public requires --notarization evidence")
        payload["distribution"] = _notarization_distribution(notarization)
    else:
        if notarization is not None:
            raise SystemExit("Notarization evidence was supplied without --public")
        payload["distribution"] = {
            "public": False,
            "notarization_ok": False,
            "codesign_ok": False,
            "notary_status": "NotRun",
            "stapler_ok": False,
            "gatekeeper_ok": False,
            "artifact_sha256": "",
        }

    errors = validate(payload, require_public_distribution=public)
    if errors:
        raise SystemExit("GA evidence is incomplete: " + ", ".join(errors))
    return payload


def _write_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    try:
        os.chmod(temporary, 0o600)
    except OSError:
        pass
    os.replace(temporary, path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compose canonical Lumi 4.0.0 GA release evidence without manual JSON editing.")
    parser.add_argument("target", type=Path, help="Physical target-Mac evidence after verified governance fields are applied.")
    parser.add_argument("--notarization", type=Path, help="Developer-ID/notarization evidence emitted by notarize_macos_app.sh.")
    parser.add_argument("--public", action="store_true", help="Require and merge public-distribution notarization evidence.")
    parser.add_argument("--output", type=Path, default=Path("release-evidence/4.0.0-ga.json"))
    args = parser.parse_args(argv)

    target = _load(args.target.expanduser())
    notarization = _load(args.notarization.expanduser()) if args.notarization else None
    payload = compose(target, notarization=notarization, public=args.public)
    output = args.output.expanduser()
    _write_atomic(output, payload)
    print(json.dumps({"ok": True, "output": str(output), "candidate_commit": payload["candidate_commit"], "public": args.public}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
