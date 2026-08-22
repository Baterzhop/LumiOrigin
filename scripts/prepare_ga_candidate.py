#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys

CURRENT = "4.0.0rc5"
FINAL = "4.0.0"

REPLACEMENTS: dict[str, tuple[tuple[str, str], ...]] = {
    "services/core/src/lumi_core/__init__.py": ((CURRENT, FINAL),),
    "services/core/pyproject.toml": ((CURRENT, FINAL),),
    "scripts/build_macos_app.sh": (("${LUMI_VERSION:-4.0.0rc5}", "${LUMI_VERSION:-4.0.0}"),),
    "scripts/notarize_macos_app.sh": (("${LUMI_VERSION:-4.0.0rc5}", "${LUMI_VERSION:-4.0.0}"),),
    ".github/workflows/v4-ci.yml": (("Lumi-macOS-4.0.0rc5.zip", "Lumi-macOS-4.0.0.zip"),),
}


class PromotionError(RuntimeError):
    pass


def plan_updates(root: Path) -> dict[Path, str]:
    updates: dict[Path, str] = {}
    for relative, replacements in REPLACEMENTS.items():
        path = root / relative
        if not path.is_file():
            raise PromotionError(f"required_file_missing:{relative}")
        original = path.read_text(encoding="utf-8")
        updated = original
        for old, new in replacements:
            if old not in updated:
                raise PromotionError(f"expected_release_marker_missing:{relative}:{old}")
            updated = updated.replace(old, new)
        if updated == original:
            raise PromotionError(f"no_change_planned:{relative}")
        updates[path] = updated
    return updates


def apply_updates(updates: dict[Path, str]) -> None:
    for path, content in updates.items():
        path.write_text(content, encoding="utf-8")


def verify_consistency(root: Path) -> None:
    init_text = (root / "services/core/src/lumi_core/__init__.py").read_text(encoding="utf-8")
    pyproject = (root / "services/core/pyproject.toml").read_text(encoding="utf-8")
    build = (root / "scripts/build_macos_app.sh").read_text(encoding="utf-8")
    notarize = (root / "scripts/notarize_macos_app.sh").read_text(encoding="utf-8")
    ci = (root / ".github/workflows/v4-ci.yml").read_text(encoding="utf-8")

    version_match = re.search(r'__version__\s*=\s*["\x27]([^"\x27]+)', init_text)
    if not version_match or version_match.group(1) != FINAL:
        raise PromotionError("core_version_not_final")
    if f'version = "{FINAL}"' not in pyproject:
        raise PromotionError("pyproject_version_not_final")
    if "${LUMI_VERSION:-4.0.0}" not in build or "${LUMI_VERSION:-4.0.0}" not in notarize:
        raise PromotionError("macos_default_version_not_final")
    if "Lumi-macOS-4.0.0.zip" not in ci or "Lumi-macOS-4.0.0rc5.zip" in ci:
        raise PromotionError("ci_artifact_version_not_final")


def _git(root: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout.strip()


def _assert_safe_candidate_branch(root: Path) -> str:
    branch = _git(root, "branch", "--show-current")
    if branch == "main" or not branch.startswith("lumi-v4-ga-candidate"):
        raise PromotionError("run_only_on_lumi-v4-ga-candidate_branch")
    if _git(root, "status", "--porcelain=v1"):
        raise PromotionError("working_tree_must_be_clean")
    return branch


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Prepare a dedicated Lumi V4 4.0.0 physical-acceptance candidate branch. Never run this directly on main."
    )
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--apply", action="store_true", help="Write the version promotion. Without this flag the command is read-only.")
    args = parser.parse_args(argv)
    root = args.root.expanduser().resolve()

    try:
        updates = plan_updates(root)
        if not args.apply:
            print("GA candidate promotion plan (read-only):")
            for path in updates:
                print(path.relative_to(root))
            print("Re-run with --apply only on a clean branch named lumi-v4-ga-candidate*.")
            return 0
        branch = _assert_safe_candidate_branch(root)
        apply_updates(updates)
        verify_consistency(root)
    except Exception as exc:
        print(f"{type(exc).__name__}:{exc}", file=sys.stderr)
        return 1

    print(f"Prepared Lumi {FINAL} candidate on {branch}.")
    print("Next: review the diff, run full V4 CI, then perform physical-Mac GA acceptance on this exact commit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
