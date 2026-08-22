from __future__ import annotations

from pathlib import Path
import subprocess


def test_branch_protection_configurator_is_syntax_valid_and_fail_closed():
    root = Path(__file__).resolve().parents[3]
    script = root / "scripts" / "configure_branch_protection.sh"
    assert script.is_file()

    subprocess.run(["bash", "-n", str(script)], check=True)
    content = script.read_text(encoding="utf-8")

    assert "APPLY=0" in content
    assert "--apply" in content
    assert "--evidence" in content
    assert '"allow_force_pushes": False' in content
    assert '"allow_deletions": False' in content
    assert '"required_conversation_resolution": True' in content
    assert "core (ubuntu-latest, 3.12)" in content
    assert "core (macos-14, 3.12)" in content
    assert "macos-client" in content
    assert "macos-install-smoke" in content
    assert "Branch protection applied and verified." in content
    assert '"main_protected": True' in content
    assert '"pull_requests_required": True' in content
    assert '"v4_ci_required": True' in content
    assert '"force_push_blocked": True' in content
    assert '"deletion_blocked": True' in content
