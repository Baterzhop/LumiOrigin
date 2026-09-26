#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile

from validate_ga_evidence import validate
from verify_ga_promotion import EVIDENCE, _git, verify

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
    source = payload.get("source_commit")
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source):
        errors.append("notarization.source_commit_invalid")
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
        "source_commit": source,
    }


def compose(target: dict, *, expected_candidate: str, notarization: dict | None = None, public: bool = False) -> dict:
    payload = json.loads(json.dumps(target))
    if payload.get("schema_version") != 1 or payload.get("version") != "4.0.0":
        raise SystemExit("Target evidence is not a Lumi 4.0.0 schema_version=1 document")
    if not re.fullmatch(r"[0-9a-f]{40}", expected_candidate) or payload.get("candidate_commit") != expected_candidate:
        raise SystemExit("candidate_commit_does_not_match_expected_candidate")

    if public:
        if notarization is None:
            raise SystemExit("--public requires --notarization evidence")
        payload["distribution"] = _notarization_distribution(notarization)
    else:
        if notarization is not None:
            raise SystemExit("Notarization evidence was supplied without --public")
        if (payload.get("distribution") or {}).get("public") is not False:
            raise SystemExit("Refusing to downgrade or infer the distribution mode; use --public with notarization evidence")
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
    descriptor, name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compose canonical Lumi 4.0.0 GA release evidence without manual JSON editing.")
    parser.add_argument("target", type=Path, help="Physical target-Mac evidence after verified governance fields are applied.")
    parser.add_argument("--notarization", type=Path, help="Developer-ID/notarization evidence emitted by notarize_macos_app.sh.")
    parser.add_argument("--public", action="store_true", help="Require and merge public-distribution notarization evidence.")
    parser.add_argument("--expected-candidate", required=True, help="Full SHA recorded when physical acceptance was run.")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, default=Path("release-evidence/4.0.0-ga.json"))
    args = parser.parse_args(argv)

    target = _load(args.target.expanduser())
    notarization = _load(args.notarization.expanduser()) if args.notarization else None
    payload = compose(target, expected_candidate=args.expected_candidate, notarization=notarization, public=args.public)
    repo = args.repo.expanduser().resolve()
    # The assembled evidence may be uncommitted; all source inputs must already be committed.
    if _git(repo, "status", "--porcelain=v1", "--", ".", f":(exclude){EVIDENCE}").stdout:
        raise SystemExit("Commit the promotion source before composing evidence (working_tree_must_be_clean)")
    errors = verify(repo, payload, "HEAD", require_committed_evidence=False)
    if errors:
        raise SystemExit("GA provenance is invalid: " + ", ".join(errors))
    output = args.output.expanduser()
    _write_atomic(output, payload)
    print(json.dumps({"ok": True, "output": str(output), "candidate_commit": payload["candidate_commit"], "public": args.public}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
