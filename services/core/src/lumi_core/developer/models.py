from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class DeveloperFileChange(BaseModel):
    model_config = ConfigDict(extra="forbid")

    path: str = Field(min_length=1, max_length=500)
    operation: Literal["create", "replace"]
    content: str = Field(max_length=200_000)
    reason: str = Field(min_length=1, max_length=2_000)


class DeveloperProposal(BaseModel):
    model_config = ConfigDict(extra="forbid")

    summary: str = Field(min_length=1, max_length=500)
    rationale: str = Field(min_length=1, max_length=4_000)
    changes: list[DeveloperFileChange] = Field(default_factory=list, max_length=8)


class DeveloperCheckResult(BaseModel):
    name: str
    command: list[str]
    status: Literal["passed", "failed", "skipped"]
    return_code: int | None = None
    output: str = ""


class DeveloperSessionView(BaseModel):
    id: str
    goal: str
    status: str
    repository_root: str
    base_branch: str
    branch_name: str | None = None
    proposal: DeveloperProposal | None = None
    proposed_diff: str | None = None
    checks: list[str] = Field(default_factory=list)
    validation: list[DeveloperCheckResult] = Field(default_factory=list)
    commit_sha: str | None = None
    pr_url: str | None = None
    error: str | None = None
    created_at: str
    updated_at: str
