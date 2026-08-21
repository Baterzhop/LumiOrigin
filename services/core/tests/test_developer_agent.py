from __future__ import annotations

from pathlib import Path
import subprocess

import pytest

from lumi_core.developer import (
    DeveloperFileChange,
    DeveloperProposal,
    DeveloperRuntime,
    DeveloperStore,
    GitRepository,
    RepositoryError,
)
from lumi_core.storage.database import Database


class StaticPlanner:
    def __init__(self, proposal: DeveloperProposal):
        self.proposal = proposal

    async def propose(self, *, goal: str, repository_snapshot: str) -> DeveloperProposal:
        assert goal
        assert "repository_tree" in repository_snapshot
        return self.proposal


class FakePublisher:
    configured = True

    def __init__(self):
        self.calls: list[dict] = []

    async def create_pull_request(self, **kwargs) -> str:
        self.calls.append(kwargs)
        return "https://github.com/example/lumi/pull/123"


def git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout.strip()


def make_repository(tmp_path: Path) -> tuple[Path, Path]:
    root = tmp_path / "repo"
    remote = tmp_path / "remote.git"
    root.mkdir()
    subprocess.run(["git", "init", "--bare", str(remote)], check=True, stdout=subprocess.PIPE)
    subprocess.run(["git", "init", "-b", "main", str(root)], check=True, stdout=subprocess.PIPE)
    git(root, "config", "user.email", "lumi-tests@example.invalid")
    git(root, "config", "user.name", "Lumi Tests")
    (root / "README.md").write_text("# Demo\n\nold\n", encoding="utf-8")
    git(root, "add", "README.md")
    git(root, "commit", "-m", "initial")
    git(root, "remote", "add", "origin", str(remote))
    return root, remote


async def test_developer_agent_requires_two_explicit_stages_and_never_merges(tmp_path):
    root, remote = make_repository(tmp_path)
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    proposal = DeveloperProposal(
        summary="Improve demo README",
        rationale="Keep the change deliberately small for the developer workflow test.",
        changes=[
            DeveloperFileChange(
                path="README.md",
                operation="replace",
                content="# Demo\n\nnew\n",
                reason="Update the demo text.",
            )
        ],
    )
    publisher = FakePublisher()
    runtime = DeveloperRuntime(
        store=DeveloperStore(db),
        repository=GitRepository(root),
        planner=StaticPlanner(proposal),
        publisher=publisher,
        base_branch="main",
    )

    session = await runtime.create_session("Improve the demo README")
    assert session.status == "awaiting_plan_approval"
    assert git(root, "branch", "--show-current") == "main"
    assert (root / "README.md").read_text(encoding="utf-8") == "# Demo\n\nold\n"

    session = await runtime.approve_plan(session.id)
    assert session.status == "ready_to_publish"
    assert session.branch_name and session.branch_name.startswith("lumi/dev-")
    assert git(root, "branch", "--show-current") == session.branch_name
    assert (root / "README.md").read_text(encoding="utf-8") == "# Demo\n\nnew\n"
    assert publisher.calls == []

    session = await runtime.publish(session.id)
    assert session.status == "published"
    assert session.commit_sha
    assert session.pr_url == "https://github.com/example/lumi/pull/123"
    assert len(publisher.calls) == 1
    pushed = subprocess.run(
        ["git", "--git-dir", str(remote), "rev-parse", f"refs/heads/{session.branch_name}"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    assert pushed == session.commit_sha
    assert git(root, "branch", "--show-current") == session.branch_name


async def test_developer_agent_create_only_change_has_reviewable_actual_diff(tmp_path):
    root, _ = make_repository(tmp_path)
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    proposal = DeveloperProposal(
        summary="Add a note",
        rationale="Exercise safe creation of a new UTF-8 text file.",
        changes=[
            DeveloperFileChange(
                path="docs/note.md",
                operation="create",
                content="# New note\n\nCreated by reviewed proposal.\n",
                reason="Add documentation.",
            )
        ],
    )
    runtime = DeveloperRuntime(
        store=DeveloperStore(db),
        repository=GitRepository(root),
        planner=StaticPlanner(proposal),
        publisher=FakePublisher(),
        base_branch="main",
    )

    session = await runtime.create_session("Add a note")
    session = await runtime.approve_plan(session.id)
    assert session.status == "ready_to_publish"
    assert session.proposed_diff is not None
    assert "/dev/null" in session.proposed_diff
    assert "b/docs/note.md" in session.proposed_diff
    assert (root / "docs/note.md").exists()


async def test_developer_validation_is_fail_closed_when_local_checks_are_disabled(tmp_path):
    root, _ = make_repository(tmp_path)
    (root / "services/core/tests").mkdir(parents=True)
    (root / "services/core/tests/test_placeholder.py").write_text("def test_ok():\n    assert True\n", encoding="utf-8")
    git(root, "add", "services/core/tests/test_placeholder.py")
    git(root, "commit", "-m", "add tests")

    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    proposal = DeveloperProposal(
        summary="Add core module",
        rationale="A Python-core path should require the fixed Python validation profile.",
        changes=[
            DeveloperFileChange(
                path="services/core/example.py",
                operation="create",
                content="VALUE = 1\n",
                reason="Add module.",
            )
        ],
    )
    runtime = DeveloperRuntime(
        store=DeveloperStore(db),
        repository=GitRepository(root, allow_local_checks=False),
        planner=StaticPlanner(proposal),
        publisher=FakePublisher(),
        base_branch="main",
    )

    session = await runtime.create_session("Add core module")
    session = await runtime.approve_plan(session.id)
    assert session.status == "validation_incomplete"
    assert session.error == "developer_validation_incomplete"
    assert session.validation[0].status == "skipped"
    assert session.validation[0].output == "local_check_execution_disabled"
    with pytest.raises(ValueError, match="developer_session_not_ready_to_publish"):
        await runtime.publish(session.id)


async def test_developer_plan_can_be_denied_without_mutation(tmp_path):
    root, _ = make_repository(tmp_path)
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    proposal = DeveloperProposal(
        summary="Change README",
        rationale="Test denial.",
        changes=[DeveloperFileChange(path="README.md", operation="replace", content="denied\n", reason="test")],
    )
    runtime = DeveloperRuntime(
        store=DeveloperStore(db),
        repository=GitRepository(root),
        planner=StaticPlanner(proposal),
        publisher=FakePublisher(),
        base_branch="main",
    )
    session = await runtime.create_session("Change README")
    denied = runtime.deny_plan(session.id)
    assert denied.status == "denied"
    assert (root / "README.md").read_text(encoding="utf-8") == "# Demo\n\nold\n"
    assert git(root, "branch", "--show-current") == "main"


async def test_developer_agent_rejects_dirty_repository(tmp_path):
    root, _ = make_repository(tmp_path)
    (root / "README.md").write_text("dirty\n", encoding="utf-8")
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    proposal = DeveloperProposal(
        summary="Change README",
        rationale="Test dirty guard.",
        changes=[DeveloperFileChange(path="README.md", operation="replace", content="new\n", reason="test")],
    )
    runtime = DeveloperRuntime(
        store=DeveloperStore(db),
        repository=GitRepository(root),
        planner=StaticPlanner(proposal),
        publisher=FakePublisher(),
        base_branch="main",
    )
    with pytest.raises(RepositoryError, match="developer_repository_dirty"):
        await runtime.create_session("Change README")


def test_developer_repository_rejects_escape_paths(tmp_path):
    root, _ = make_repository(tmp_path)
    repository = GitRepository(root)
    change = DeveloperFileChange(path="../outside.txt", operation="create", content="x", reason="escape")
    with pytest.raises(RepositoryError):
        repository.validate_change(change)


def test_developer_repository_rejects_symlink_escape(tmp_path):
    root, _ = make_repository(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    (root / "link").symlink_to(outside, target_is_directory=True)
    repository = GitRepository(root)
    change = DeveloperFileChange(path="link/escape.txt", operation="create", content="x", reason="escape")
    with pytest.raises(RepositoryError, match="developer_path_outside_repository"):
        repository.validate_change(change)
