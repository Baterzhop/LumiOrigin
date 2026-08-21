from __future__ import annotations

import re
from typing import Protocol

import httpx


class PublishError(RuntimeError):
    pass


class PullRequestPublisher(Protocol):
    @property
    def configured(self) -> bool: ...

    async def create_pull_request(
        self,
        *,
        branch: str,
        base_branch: str,
        title: str,
        body: str,
    ) -> str: ...


class GitHubPullRequestPublisher:
    def __init__(
        self,
        *,
        repository: str | None,
        token: str | None,
        timeout_seconds: float = 30,
    ):
        repository = (repository or "").strip()
        if repository and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("invalid_github_repository")
        self.repository = repository or None
        self.token = (token or "").strip() or None
        self.timeout_seconds = timeout_seconds

    @property
    def configured(self) -> bool:
        return bool(self.repository and self.token)

    async def create_pull_request(
        self,
        *,
        branch: str,
        base_branch: str,
        title: str,
        body: str,
    ) -> str:
        if not self.configured:
            raise PublishError("github_publisher_not_configured")
        url = f"https://api.github.com/repos/{self.repository}/pulls"
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Lumi-Developer-Agent",
        }
        payload = {
            "title": title[:240],
            "head": branch,
            "base": base_branch,
            "body": body[:60_000],
            "draft": True,
        }
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            response = await client.post(url, headers=headers, json=payload)
            if response.status_code not in {200, 201}:
                raise PublishError(f"github_pr_failed:{response.status_code}")
            data = response.json()
        html_url = str(data.get("html_url") or "").strip()
        if not html_url.startswith("https://github.com/"):
            raise PublishError("github_pr_invalid_response")
        return html_url
