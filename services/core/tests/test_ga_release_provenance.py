from __future__ import annotations

from pathlib import Path


def test_final_release_workflow_is_bound_to_physical_candidate_tree():
    root = Path(__file__).resolve().parents[3]
    workflow = (root / ".github" / "workflows" / "v4-release.yml").read_text(encoding="utf-8")

    assert "fetch-depth: 0" in workflow
    assert "scripts/assemble_ga_evidence.py" in workflow
    assert "git merge-base --is-ancestor" in workflow
    assert 'CANDIDATE_VERSION" = "4.0.0"' in workflow
    assert "git diff --name-only \"$CANDIDATE\"..HEAD" in workflow
    assert 'release-evidence/4.0.0-ga.json' in workflow
    assert "Final tag differs from the physical acceptance candidate outside the evidence file" in workflow
