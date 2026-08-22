from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "prepare_ga_candidate.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("lumi_prepare_ga_candidate", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _fixture_tree(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    files = {
        "services/core/src/lumi_core/__init__.py": '__version__ = "4.0.0rc5"\n',
        "services/core/pyproject.toml": '[project]\nversion = "4.0.0rc5"\n',
        "scripts/build_macos_app.sh": 'VERSION="${LUMI_VERSION:-4.0.0rc5}"\n',
        "scripts/notarize_macos_app.sh": 'VERSION="${LUMI_VERSION:-4.0.0rc5}"\n',
        ".github/workflows/v4-ci.yml": 'test -f dist/Lumi-macOS-4.0.0rc5.zip\n',
    }
    for relative, content in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    return root


def test_pure_candidate_promotion_changes_only_release_markers(tmp_path: Path):
    module = _load_module()
    root = _fixture_tree(tmp_path)
    updates = module.plan_updates(root)
    assert {str(path.relative_to(root)) for path in updates} == set(module.REPLACEMENTS)
    module.apply_updates(updates)
    module.verify_consistency(root)

    assert '4.0.0rc5' not in (root / "services/core/src/lumi_core/__init__.py").read_text(encoding="utf-8")
    assert 'version = "4.0.0"' in (root / "services/core/pyproject.toml").read_text(encoding="utf-8")
    assert "Lumi-macOS-4.0.0.zip" in (root / ".github/workflows/v4-ci.yml").read_text(encoding="utf-8")


def test_promotion_fails_when_expected_marker_drifted(tmp_path: Path):
    module = _load_module()
    root = _fixture_tree(tmp_path)
    (root / "services/core/pyproject.toml").write_text('[project]\nversion = "4.1.0"\n', encoding="utf-8")
    try:
        module.plan_updates(root)
    except module.PromotionError as exc:
        assert "expected_release_marker_missing" in str(exc)
    else:
        raise AssertionError("drifted version marker must fail")


def test_cli_default_is_read_only_on_current_checkout():
    before = subprocess.run(
        ["git", "-C", str(ROOT), "status", "--porcelain=v1"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    after = subprocess.run(
        ["git", "-C", str(ROOT), "status", "--porcelain=v1"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout
    assert result.returncode == 0, result.stdout + result.stderr
    assert "read-only" in result.stdout
    assert before == after


def test_apply_refuses_non_candidate_branch():
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--apply"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 1
    assert "run_only_on_lumi-v4-ga-candidate_branch" in result.stderr
