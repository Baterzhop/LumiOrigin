from __future__ import annotations

from pathlib import Path
import subprocess

import pytest

from lumi_core.developer import DeveloperFileChange, DeveloperProposal, DeveloperRuntime, DeveloperStore, GitRepository, RepositoryError
from lumi_core.storage.database import Database


class StaticPlanner:
    def __init__(self, proposal: DeveloperProposal):
        self.proposal = proposal

    async def propose(self, *, goal: str, repository_snapshot: str) -> DeveloperProposal:
        return self.proposal


class FakePublisher:
    configured = True

    async def create_pull_request(self, **kwargs) -> str:
        return "https://github.com/example/lumi/pull/1"


def git(root: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def make_repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-b", "main", str(root)], check=True, stdout=subprocess.PIPE)
    git(root, "config", "user.email", "lumi-tests@example.invalid")
    git(root, "config", "user.name", "Lumi Tests")
    (root / "README.md").write_text("old\n", encoding="utf-8")
    git(root, "add", "README.md")
    git(root, "commit", "-m", "initial")
    return root


async def test_publish_refuses_tampered_planned_file(tmp_path):
    root = make_repo(tmp_path)
    database = Database(tmp_path / "lumi.sqlite3")
    database.migrate()
    proposal = DeveloperProposal(
        summary="Update README",
        rationale="Test exact proposal binding.",
        changes=[
            DeveloperFileChange(
                path="README.md",
                operation="replace",
                content="approved\n",
                reason="Reviewed replacement.",
            )
        ],
    )
    runtime = DeveloperRuntime(
        store=DeveloperStore(database),
        repository=GitRepository(root),
        planner=StaticPlanner(proposal),
        publisher=FakePublisher(),
        base_branch="main",
    )

    session = await runtime.create_session("Update README")
    session = await runtime.approve_plan(session.id)
    assert session.status == "ready_to_publish"

    (root / "README.md").write_text("tampered after approval\n", encoding="utf-8")
    with pytest.raises(RepositoryError, match="developer_planned_content_changed"):
        await runtime.publish(session.id)
