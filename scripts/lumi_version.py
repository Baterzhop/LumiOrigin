#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.metadata
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYPROJECT = ROOT / "services" / "core" / "pyproject.toml"
PACKAGE_NAME = "lumi-core"
_VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+)*(?:[A-Za-z0-9._+-]*)$")


def project_version() -> str:
    data = tomllib.loads(PYPROJECT.read_text(encoding="utf-8"))
    version = str(data["project"]["version"]).strip()
    if not version or not _VERSION_RE.fullmatch(version):
        raise SystemExit(f"Invalid Lumi project version in {PYPROJECT}: {version!r}")
    return version


def installed_version() -> str:
    try:
        return importlib.metadata.version(PACKAGE_NAME)
    except importlib.metadata.PackageNotFoundError as exc:
        raise SystemExit(
            "lumi-core is not installed; install the tested Core environment before using --verify-runtime"
        ) from exc


def verify_tag(tag: str, version: str) -> None:
    expected = f"v{version}"
    if tag != expected:
        raise SystemExit(f"Release tag/version mismatch: tag={tag!r}, expected={expected!r}")


def verify_runtime(version: str) -> None:
    runtime = installed_version()
    if runtime != version:
        raise SystemExit(
            f"Installed lumi-core version mismatch: runtime={runtime!r}, project={version!r}"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Read and validate the canonical Lumi release version from services/core/pyproject.toml."
    )
    parser.add_argument("--artifact-name", action="store_true", help="Print the macOS release ZIP filename.")
    parser.add_argument("--verify-tag", metavar="TAG", help="Require TAG to equal v<project-version>.")
    parser.add_argument(
        "--verify-runtime",
        action="store_true",
        help="Require installed lumi-core package metadata to equal the project version.",
    )
    args = parser.parse_args(argv)

    version = project_version()
    if args.verify_tag:
        verify_tag(args.verify_tag, version)
    if args.verify_runtime:
        verify_runtime(version)

    if args.artifact_name:
        print(f"Lumi-macOS-{version}.zip")
    else:
        print(version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
