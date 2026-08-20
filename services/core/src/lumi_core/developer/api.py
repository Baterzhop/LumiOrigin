from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from lumi_core.config import Settings
from lumi_core.models.gateway import ModelGateway
from lumi_core.storage.database import Database

from .planner import LLMDeveloperPlanner
from .publisher import GitHubPullRequestPublisher, PublishError
from .repository import GitRepository, RepositoryError
from .runtime import DeveloperRuntime
from .store import DeveloperStore


class DeveloperSessionCreateRequest(BaseModel):
    goal: str = Field(min_length=1, max_length=50_000)


class ExplicitApprovalRequest(BaseModel):
    approved_by_user: bool = False


class DeveloperAPI:
    def __init__(self, settings: Settings, database: Database, model_gateway: ModelGateway):
        self.settings = settings
        self.runtime: DeveloperRuntime | None = None
        self.disabled_reason: str | None = None

        repo_root = settings.developer_repo_root
        if repo_root is None:
            self.disabled_reason = "developer_repo_not_configured"
            return

        resolved = repo_root.expanduser().resolve()
        runtime_source_root = Path(__file__).resolve().parents[5]
        overlaps_runtime = (
            resolved == runtime_source_root
            or runtime_source_root in resolved.parents
            or resolved in runtime_source_root.parents
        )
        if overlaps_runtime:
            self.disabled_reason = "developer_repo_must_be_separate_checkout"
            return

        try:
            publisher = GitHubPullRequestPublisher(
                repository=settings.developer_github_repository,
                token=settings.developer_github_token,
            )
        except ValueError as exc:
            self.disabled_reason = str(exc)
            return

        repository = GitRepository(
            resolved,
            max_read_bytes=settings.developer_max_read_bytes,
            command_timeout_seconds=settings.developer_command_timeout_seconds,
            allow_local_checks=settings.developer_allow_local_checks,
        )
        self.runtime = DeveloperRuntime(
            store=DeveloperStore(database),
            repository=repository,
            planner=LLMDeveloperPlanner(model_gateway),
            publisher=publisher,
            base_branch=settings.developer_base_branch,
        )

    def require_runtime(self) -> DeveloperRuntime:
        if self.runtime is None:
            raise HTTPException(status_code=503, detail=self.disabled_reason or "developer_agent_disabled")
        return self.runtime


def build_developer_router(settings: Settings, database: Database, model_gateway: ModelGateway) -> APIRouter:
    service = DeveloperAPI(settings, database, model_gateway)
    router = APIRouter(prefix="/v1/developer", tags=["developer"])

    @router.get("/status")
    async def developer_status() -> dict:
        if service.runtime is None:
            return {
                "enabled": False,
                "repository_ok": False,
                "repository_root": str(settings.developer_repo_root) if settings.developer_repo_root else None,
                "base_branch": settings.developer_base_branch,
                "current_branch": None,
                "clean": False,
                "publisher_configured": bool(settings.developer_github_repository and settings.developer_github_token),
                "local_checks_enabled": settings.developer_allow_local_checks,
                "error": service.disabled_reason,
            }
        result = await service.runtime.status()
        result["local_checks_enabled"] = settings.developer_allow_local_checks
        return result

    @router.post("/sessions")
    async def create_developer_session(request: DeveloperSessionCreateRequest) -> dict:
        runtime = service.require_runtime()
        try:
            session = await runtime.create_session(request.goal)
            return session.model_dump()
        except (ValueError, RepositoryError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"developer_planning_failed:{type(exc).__name__}") from exc

    @router.get("/sessions/{session_id}")
    def get_developer_session(session_id: str) -> dict:
        runtime = service.require_runtime()
        try:
            return runtime.get(session_id).model_dump()
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @router.get("/sessions/{session_id}/events")
    def developer_session_events(session_id: str) -> dict:
        runtime = service.require_runtime()
        try:
            return {"session_id": session_id, "events": runtime.events(session_id)}
        except ValueError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @router.post("/sessions/{session_id}/approve-plan")
    async def approve_developer_plan(session_id: str, request: ExplicitApprovalRequest) -> dict:
        if not request.approved_by_user:
            raise HTTPException(status_code=400, detail="explicit_user_approval_required")
        runtime = service.require_runtime()
        try:
            return (await runtime.approve_plan(session_id)).model_dump()
        except (ValueError, RepositoryError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @router.post("/sessions/{session_id}/deny-plan")
    def deny_developer_plan(session_id: str) -> dict:
        runtime = service.require_runtime()
        try:
            return runtime.deny_plan(session_id).model_dump()
        except ValueError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @router.post("/sessions/{session_id}/publish")
    async def publish_developer_session(session_id: str, request: ExplicitApprovalRequest) -> dict:
        if not request.approved_by_user:
            raise HTTPException(status_code=400, detail="explicit_user_approval_required")
        runtime = service.require_runtime()
        try:
            return (await runtime.publish(session_id)).model_dump()
        except PublishError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except (ValueError, RepositoryError) as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    return router
