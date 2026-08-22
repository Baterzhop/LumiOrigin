from __future__ import annotations

import subprocess
import sys
import tomllib
from pathlib import Path

from lumi_core import __version__

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "lumi_version.py"
PYPROJECT = ROOT / "services" / "core" / "pyproject.toml"


def _project_version() -> str:
    return tomllib.loads(PYPROJECT.read_text(encoding="utf-8"))["project"]["version"]


def test_release_version_helper_matches_pyproject() -> None:
    expected = _project_version()
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    assert result.stdout.strip() == expected


def test_core_module_version_matches_project_version() -> None:
    assert __version__ == _project_version()


def test_release_artifact_name_is_derived_from_project_version() -> None:
    expected = _project_version()
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--artifact-name"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    assert result.stdout.strip() == f"Lumi-macOS-{expected}.zip"


def test_release_tag_must_match_project_version() -> None:
    version = _project_version()
    ok = subprocess.run(
        [sys.executable, str(SCRIPT), "--verify-tag", f"v{version}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert ok.returncode == 0

    bad = subprocess.run(
        [sys.executable, str(SCRIPT), "--verify-tag", "v0.0.0-wrong"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert bad.returncode != 0
    assert "tag/version mismatch" in bad.stderr.lower()


def test_installed_runtime_metadata_matches_project_version() -> None:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--verify-runtime"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == _project_version()
