from __future__ import annotations

from pathlib import Path
import subprocess

from lumi_core.developer import DeveloperFileChange, DeveloperProposal, DeveloperRuntime, DeveloperStore, GitRepository
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


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout.strip()


def make_repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-b", "main", str(root)], check=True, stdout=subprocess.PIPE)
    git(root, "config", "user.email", "lumi-tests@example.invalid")
    git(root, "config", "user.name", "Lumi Tests")
    tests = root / "services/core/tests"
    tests.mkdir(parents=True)
    (tests / "test_placeholder.py").write_text("def test_ok():\n    assert True\n", encoding="utf-8")
    git(root, "add", ".")
    git(root, "commit", "-m", "initial")
    return root


async def test_validation_can_be_explicitly_retried_after_checks_are_enabled(tmp_path):
    root = make_repo(tmp_path)
    database = Database(tmp_path / "lumi.sqlite3")
    database.migrate()
    proposal = DeveloperProposal(
        summary="Add core module",
        rationale="Exercise validation retry without changing the approved proposal.",
        changes=[
            DeveloperFileChange(
                path="services/core/example.py",
                operation="create",
                content="VALUE = 1\n",
                reason="Add deterministic example module.",
            )
        ],
    )
    repository = GitRepository(root, allow_local_checks=False)
    runtime = DeveloperRuntime(
        store=DeveloperStore(database),
        repository=repository,
        planner=StaticPlanner(proposal),
        publisher=FakePublisher(),
        base_branch="main",
    )

    session = await runtime.create_session("Add core module")
    session = await runtime.approve_plan(session.id)
    assert session.status == "validation_incomplete"
    assert session.validation[0].status == "skipped"

    repository.allow_local_checks = True
    session = await runtime.revalidate(session.id)
    assert session.status == "ready_to_publish"
    assert session.error is None
    assert session.validation[0].status == "passed"
    assert session.validation[0].return_code == 0

    events = runtime.events(session.id)
    assert any(event["event_type"] == "validation_retry_approved" for event in events)
