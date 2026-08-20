from __future__ import annotations

from datetime import datetime, timezone
import json
import re
import uuid

from .models import DeveloperProposal, DeveloperSessionView
from .planner import DeveloperPlanner
from .publisher import PullRequestPublisher, PublishError
from .repository import GitRepository, RepositoryError
from .store import DeveloperStore


class DeveloperRuntime:
    def __init__(
        self,
        *,
        store: DeveloperStore,
        repository: GitRepository,
        planner: DeveloperPlanner,
        publisher: PullRequestPublisher,
        base_branch: str = "main",
    ):
        self.store = store
        self.repository = repository
        self.planner = planner
        self.publisher = publisher
        self.base_branch = base_branch.strip() or "main"

    async def status(self) -> dict:
        try:
            await self.repository.verify()
            branch = await self.repository.current_branch()
            clean = await self.repository.is_clean()
            repository_ok = True
            error = None
        except Exception as exc:
            branch = None
            clean = False
            repository_ok = False
            error = type(exc).__name__
        return {
            "enabled": True,
            "repository_ok": repository_ok,
            "repository_root": str(self.repository.root),
            "base_branch": self.base_branch,
            "current_branch": branch,
            "clean": clean,
            "publisher_configured": self.publisher.configured,
            "error": error,
        }

    async def create_session(self, goal: str) -> DeveloperSessionView:
        clean_goal = goal.strip()
        if not clean_goal:
            raise ValueError("empty_developer_goal")
        await self.repository.verify()
        if not await self.repository.is_clean():
            raise RepositoryError("developer_repository_dirty")
        branch = await self.repository.current_branch()
        if branch != self.base_branch:
            raise RepositoryError("developer_must_start_on_base_branch")

        snapshot = await self.repository.snapshot(clean_goal)
        proposal = await self.planner.propose(goal=clean_goal, repository_snapshot=snapshot)
        self._validate_proposal(proposal)
        proposed_diff = self.repository.proposed_diff(proposal.changes)
        if not proposed_diff.strip():
            raise ValueError("developer_proposal_has_no_diff")
        checks = self._checks_for(proposal)
        session_id = self.store.create_session(
            goal=clean_goal,
            repository_root=str(self.repository.root),
            base_branch=self.base_branch,
            status="awaiting_plan_approval",
            proposal=proposal,
            proposed_diff=proposed_diff,
            checks=checks,
        )
        self.store.add_event(
            session_id,
            "proposal_ready",
            {"change_count": len(proposal.changes), "checks": checks},
        )
        return self._get(session_id)

    async def approve_plan(self, session_id: str) -> DeveloperSessionView:
        session = self._get(session_id)
        if session.status != "awaiting_plan_approval" or session.proposal is None:
            raise ValueError("developer_session_not_awaiting_plan_approval")
        await self.repository.verify()
        if not await self.repository.is_clean():
            raise RepositoryError("developer_repository_dirty")
        branch = await self.repository.current_branch()
        if branch != session.base_branch:
            raise RepositoryError("developer_base_branch_changed")

        self._validate_proposal(session.proposal)
        current_diff = self.repository.proposed_diff(session.proposal.changes)
        if current_diff != (session.proposed_diff or ""):
            raise RepositoryError("developer_repository_changed_since_proposal")

        branch_name = self._branch_name(session.goal)
        self.store.update(session_id, status="applying", branch_name=branch_name, error=None)
        self.store.add_event(session_id, "plan_approved", {"branch": branch_name})
        try:
            await self.repository.create_branch(branch_name, base_branch=session.base_branch)
            self.repository.apply_changes(session.proposal.changes)
            actual_diff = await self.repository.diff()
            if not actual_diff.strip():
                raise RepositoryError("developer_applied_diff_empty")
            self.store.update(session_id, proposed_diff=actual_diff, status="validating")
            await self._run_validation(session_id)
        except Exception as exc:
            self.store.update(session_id, status="failed", error=str(exc)[:2_000])
            self.store.add_event(session_id, "apply_failed", {"error": type(exc).__name__})
            raise
        return self._get(session_id)

    async def revalidate(self, session_id: str) -> DeveloperSessionView:
        session = self._get(session_id)
        if session.status not in {"validation_failed", "validation_incomplete"}:
            raise ValueError("developer_session_not_revalidatable")
        if session.proposal is None or not session.branch_name:
            raise ValueError("developer_session_incomplete")
        await self.repository.verify()
        if await self.repository.current_branch() != session.branch_name:
            raise RepositoryError("developer_wrong_branch_for_validation")
        await self._assert_only_planned_paths(session)
        self.store.update(session_id, status="validating", error=None)
        self.store.add_event(session_id, "validation_retry_approved", {})
        await self._run_validation(session_id)
        return self._get(session_id)

    def deny_plan(self, session_id: str) -> DeveloperSessionView:
        session = self._get(session_id)
        if session.status != "awaiting_plan_approval":
            raise ValueError("developer_session_not_awaiting_plan_approval")
        self.store.update(session_id, status="denied", error="user_denied_plan")
        self.store.add_event(session_id, "plan_denied", {})
        return self._get(session_id)

    async def publish(self, session_id: str) -> DeveloperSessionView:
        session = self._get(session_id)
        if session.status not in {"ready_to_publish", "publish_failed"}:
            raise ValueError("developer_session_not_ready_to_publish")
        if session.proposal is None or not session.branch_name:
            raise ValueError("developer_session_incomplete")
        if not self.publisher.configured:
            raise PublishError("github_publisher_not_configured")
        await self.repository.verify()
        if await self.repository.current_branch() != session.branch_name:
            raise RepositoryError("developer_wrong_branch_for_publish")

        planned_paths = [change.path for change in session.proposal.changes]
        changed = await self.repository.changed_paths()
        unexpected = sorted(set(changed) - set(planned_paths))
        if unexpected:
            raise RepositoryError("developer_unexpected_worktree_changes:" + ",".join(unexpected[:20]))

        self.store.update(session_id, status="publishing", error=None)
        self.store.add_event(session_id, "publish_approved", {})
        try:
            commit_sha = session.commit_sha
            if not commit_sha:
                if not changed:
                    raise RepositoryError("developer_no_changes_to_publish")
                commit_sha = await self.repository.commit(planned_paths, session.proposal.summary)
                self.store.update(session_id, commit_sha=commit_sha)
                self.store.add_event(session_id, "committed", {"commit_sha": commit_sha})

            await self.repository.push(session.branch_name)
            self.store.add_event(session_id, "pushed", {"branch": session.branch_name})
            body = self._pr_body(self._get(session_id))
            pr_url = await self.publisher.create_pull_request(
                branch=session.branch_name,
                base_branch=session.base_branch,
                title=session.proposal.summary,
                body=body,
            )
            self.store.update(session_id, status="published", pr_url=pr_url, error=None)
            self.store.add_event(session_id, "pull_request_created", {"url": pr_url})
        except Exception as exc:
            self.store.update(session_id, status="publish_failed", error=str(exc)[:2_000])
            self.store.add_event(session_id, "publish_failed", {"error": type(exc).__name__})
            raise
        return self._get(session_id)

    def get(self, session_id: str) -> DeveloperSessionView:
        return self._get(session_id)

    def events(self, session_id: str) -> list[dict]:
        self._get(session_id)
        return self.store.events(session_id)

    async def _run_validation(self, session_id: str) -> None:
        session = self._get(session_id)
        if session.proposal is None:
            raise ValueError("developer_session_incomplete")
        validation = await self.repository.run_checks(session.checks)
        validation_json = json.dumps([item.model_dump() for item in validation], ensure_ascii=False)
        failed = [item for item in validation if item.status == "failed"]
        skipped = [item for item in validation if item.status == "skipped"]

        unexpected = await self._unexpected_paths(session)
        if unexpected:
            final_status = "validation_failed"
            error = "developer_validation_created_unexpected_paths:" + ",".join(unexpected[:20])
        elif failed:
            final_status = "validation_failed"
            error = "developer_validation_failed"
        elif skipped:
            final_status = "validation_incomplete"
            error = "developer_validation_incomplete"
        else:
            final_status = "ready_to_publish"
            error = None

        self.store.update(
            session_id,
            status=final_status,
            validation_json=validation_json,
            error=error,
        )
        self.store.add_event(
            session_id,
            "validation_finished",
            {
                "status": final_status,
                "failed": [item.name for item in failed],
                "skipped": [item.name for item in skipped],
                "unexpected_paths": unexpected,
            },
        )

    async def _unexpected_paths(self, session: DeveloperSessionView) -> list[str]:
        assert session.proposal is not None
        planned = {change.path for change in session.proposal.changes}
        changed = set(await self.repository.changed_paths())
        return sorted(changed - planned)

    async def _assert_only_planned_paths(self, session: DeveloperSessionView) -> None:
        unexpected = await self._unexpected_paths(session)
        if unexpected:
            raise RepositoryError("developer_unexpected_worktree_changes:" + ",".join(unexpected[:20]))

    def _validate_proposal(self, proposal: DeveloperProposal) -> None:
        seen: set[str] = set()
        for change in proposal.changes:
            if change.path in seen:
                raise ValueError("developer_duplicate_change_path")
            seen.add(change.path)
            self.repository.validate_change(change)

    @staticmethod
    def _checks_for(proposal: DeveloperProposal) -> list[str]:
        paths = [change.path for change in proposal.changes]
        checks: list[str] = []
        if any(path.startswith("services/core/") or path.startswith("scripts/") for path in paths):
            checks.append("python-core-tests")
        if any(path.startswith("services/core/src/lumi_core/rag/") or path.startswith("evals/rag/") or path == "scripts/eval_rag.py" for path in paths):
            checks.append("rag-regression")
        if any(path.startswith("services/core/src/lumi_core/memory/") or path.startswith("evals/memory/") or path == "scripts/eval_memory.py" for path in paths):
            checks.append("memory-regression")
        if any(path.startswith("apps/macos/") for path in paths):
            checks.append("swift-tests")
        return list(dict.fromkeys(checks))

    @staticmethod
    def _branch_name(goal: str) -> str:
        slug = "-".join(re.findall(r"[a-z0-9]+", goal.lower())[:5]) or "change"
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        return f"lumi/dev-{stamp}-{slug[:40]}-{uuid.uuid4().hex[:6]}"

    @staticmethod
    def _pr_body(session: DeveloperSessionView) -> str:
        proposal = session.proposal
        assert proposal is not None
        checks = "\n".join(
            f"- `{item.name}`: **{item.status}**"
            for item in session.validation
        ) or "- No repository check profile matched these files."
        files = "\n".join(f"- `{change.path}` — {change.reason}" for change in proposal.changes)
        return (
            "## Lumi Developer Agent proposal\n\n"
            + proposal.rationale
            + "\n\n## Files\n"
            + files
            + "\n\n## Validation\n"
            + checks
            + "\n\nThis draft PR was created only after explicit user approval. Lumi never auto-merges it."
        )

    def _get(self, session_id: str) -> DeveloperSessionView:
        session = self.store.get(session_id)
        if session is None:
            raise ValueError("developer_session_not_found")
        return session
