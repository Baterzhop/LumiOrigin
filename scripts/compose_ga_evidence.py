#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from validate_ga_evidence import validate


def _read_object(path: Path) -> dict:
    payload = json.loads(path.expanduser().read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected JSON object")
    return payload


def compose(target: dict, governance: dict, distribution: dict | None = None) -> dict:
    target_section = target.get("target_mac")
    if not isinstance(target_section, dict):
        raise ValueError("target evidence is missing target_mac")
    governance_section = governance.get("governance", governance)
    if not isinstance(governance_section, dict):
        raise ValueError("governance evidence is invalid")
    if distribution is None:
        distribution_section = {
            "public": False,
            "notarization_ok": False,
            "codesign_ok": False,
            "notary_status": "NotRun",
            "stapler_ok": False,
            "gatekeeper_ok": False,
            "artifact_sha256": "",
        }
    else:
        distribution_section = distribution.get("distribution", distribution)
        if not isinstance(distribution_section, dict):
            raise ValueError("distribution evidence is invalid")
    return {
        "schema_version": 1,
        "version": "4.0.0",
        "candidate_commit": target.get("candidate_commit"),
        "target_mac": target_section,
        "governance": governance_section,
        "distribution": distribution_section,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compose and validate the final Lumi V4 4.0.0 GA evidence document.")
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--governance", type=Path, required=True)
    parser.add_argument("--distribution", type=Path)
    parser.add_argument("--output", type=Path, default=Path("release-evidence/4.0.0-ga.json"))
    parser.add_argument("--public", action="store_true", help="Require public-distribution notarization evidence")
    args = parser.parse_args(argv)
    try:
        payload = compose(
            _read_object(args.target),
            _read_object(args.governance),
            _read_object(args.distribution) if args.distribution else None,
        )
        errors = validate(payload, require_public_distribution=args.public)
        if errors:
            print(json.dumps({"ok": False, "errors": errors}, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        args.output.expanduser().parent.mkdir(parents=True, exist_ok=True)
        args.output.expanduser().write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({"ok": True, "output": str(args.output.expanduser())}, indent=2, sort_keys=True))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": f"{type(exc).__name__}:{exc}"}, indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
