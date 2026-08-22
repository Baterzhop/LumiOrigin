#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DISTRIBUTION_FIELDS = {
    "public",
    "notarization_ok",
    "codesign_ok",
    "notary_status",
    "stapler_ok",
    "gatekeeper_ok",
    "artifact_sha256",
}


class AssemblyError(RuntimeError):
    pass


def _load_json(path: Path) -> dict:
    try:
        payload = json.loads(path.expanduser().read_text(encoding="utf-8"))
    except Exception as exc:
        raise AssemblyError(f"json_read_failed:{path}:{type(exc).__name__}") from exc
    if not isinstance(payload, dict):
        raise AssemblyError(f"json_object_required:{path}")
    return payload


def _validator_module(root: Path):
    path = root / "scripts" / "validate_ga_evidence.py"
    spec = importlib.util.spec_from_file_location("lumi_validate_ga_evidence", path)
    if spec is None or spec.loader is None:
        raise AssemblyError("validator_import_failed")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _current_commit(root: Path) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    value = completed.stdout.strip()
    if not SHA_RE.fullmatch(value):
        raise AssemblyError("current_git_commit_invalid")
    return value


def _write_atomic_private(path: Path, payload: dict) -> None:
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    try:
        os.chmod(temporary, 0o600)
    except OSError:
        pass
    os.replace(temporary, path)


def assemble(
    target_evidence: dict,
    *,
    expected_candidate: str,
    notarization: dict | None = None,
    require_public: bool = False,
    validator=None,
) -> dict:
    if target_evidence.get("schema_version") != 1 or target_evidence.get("version") != "4.0.0":
        raise AssemblyError("target_evidence_schema_or_version_invalid")
    candidate = target_evidence.get("candidate_commit")
    if not isinstance(candidate, str) or not SHA_RE.fullmatch(candidate):
        raise AssemblyError("target_candidate_commit_invalid")
    if not SHA_RE.fullmatch(expected_candidate):
        raise AssemblyError("expected_candidate_commit_invalid")
    if candidate != expected_candidate:
        raise AssemblyError(f"candidate_commit_mismatch:{candidate}:{expected_candidate}")

    assembled = json.loads(json.dumps(target_evidence))
    governance = assembled.get("governance")
    if not isinstance(governance, dict):
        raise AssemblyError("governance_missing")
    for key in (
        "main_protected",
        "pull_requests_required",
        "v4_ci_required",
        "force_push_blocked",
        "deletion_blocked",
    ):
        if governance.get(key) is not True:
            raise AssemblyError(f"governance_not_verified:{key}")

    target = assembled.get("target_mac")
    if not isinstance(target, dict) or target.get("ok") is not True:
        raise AssemblyError("target_mac_not_verified")

    if notarization is not None:
        unknown = set(notarization) - (DISTRIBUTION_FIELDS | {"version", "timestamp_utc"})
        if unknown:
            raise AssemblyError("notarization_unknown_fields:" + ",".join(sorted(unknown)))
        if notarization.get("version") != "4.0.0":
            raise AssemblyError("notarization_version_must_be_4.0.0")
        distribution = assembled.get("distribution")
        if not isinstance(distribution, dict):
            raise AssemblyError("distribution_missing")
        for key in DISTRIBUTION_FIELDS:
            if key in notarization:
                distribution[key] = notarization[key]

    if require_public and notarization is None:
        raise AssemblyError("public_distribution_requires_notarization_fragment")

    if validator is not None:
        errors = validator.validate(assembled, require_public_distribution=require_public)
        if errors:
            raise AssemblyError("final_evidence_invalid:" + ",".join(errors))
    return assembled


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Assemble Lumi 4.0.0 GA evidence from verified target/governance state and optional Apple notarization evidence."
    )
    parser.add_argument("target", type=Path, help="GA evidence produced on the physical Mac and updated by verified governance tooling")
    parser.add_argument("--notarization", type=Path, help="Notarization fragment emitted by scripts/notarize_macos_app.sh")
    parser.add_argument("--public", action="store_true", help="Require complete public-distribution notarization evidence")
    parser.add_argument(
        "--expected-candidate",
        help="Expected full candidate SHA. Defaults to the current checkout HEAD.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("release-evidence/4.0.0-ga.json"),
        help="Final repository evidence path",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    try:
        expected = args.expected_candidate or _current_commit(root)
        target = _load_json(args.target)
        notarization = _load_json(args.notarization) if args.notarization else None
        validator = _validator_module(root)
        final = assemble(
            target,
            expected_candidate=expected,
            notarization=notarization,
            require_public=args.public,
            validator=validator,
        )
        _write_atomic_private(args.output, final)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": f"{type(exc).__name__}:{exc}"}, indent=2), file=sys.stderr)
        return 1

    print(
        json.dumps(
            {
                "ok": True,
                "candidate_commit": final["candidate_commit"],
                "public": bool(final.get("distribution", {}).get("public")),
                "output": str(args.output),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
