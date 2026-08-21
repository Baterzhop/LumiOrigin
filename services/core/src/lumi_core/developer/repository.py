from __future__ import annotations

import asyncio
import difflib
import os
from pathlib import Path
import re
import sys
from typing import Iterable

from .models import DeveloperCheckResult, DeveloperFileChange


class RepositoryError(RuntimeError):
    pass


class GitRepository:
    def __init__(
        self,
        root: Path,
        *,
        max_read_bytes: int = 256_000,
        command_timeout_seconds: int = 180,
        allow_local_checks: bool = False,
    ):
        self.root = root.expanduser().resolve()
        self.max_read_bytes = max(8_192, max_read_bytes)
        self.command_timeout_seconds = max(5, min(command_timeout_seconds, 900))
        self.allow_local_checks = allow_local_checks

    async def verify(self) -> None:
        if not self.root.exists() or not self.root.is_dir():
            raise RepositoryError("developer_repository_not_found")
        top = (await self._git("rev-parse", "--show-toplevel")).strip()
        if Path(top).resolve() != self.root:
            raise RepositoryError("developer_repository_root_mismatch")

    async def current_branch(self) -> str:
        return (await self._git("branch", "--show-current")).strip()

    async def is_clean(self) -> bool:
        return not (await self._git("status", "--porcelain=v1")).strip()

    async def changed_paths(self) -> list[str]:
        output = await self._git("status", "--porcelain=v1", "--untracked-files=all")
        result: list[str] = []
        for raw in output.splitlines():
            if len(raw) < 4:
                continue
            value = raw[3:]
            if " -> " in value:
                value = value.split(" -> ", 1)[1]
            result.append(value.strip().strip('"'))
        return result

    async def tracked_files(self, limit: int = 800) -> list[str]:
        output = await self._git("ls-files")
        return [line for line in output.splitlines() if line][: max(1, min(limit, 2_000))]

    async def snapshot(self, goal: str, *, max_files: int = 8) -> str:
        files = await self.tracked_files()
        selected = self._select_files(files, goal, max_files=max_files)
        tree = "\n".join(files[:500])
        parts = ["<repository_tree>\n" + tree + "\n</repository_tree>"]
        for path in selected:
            content = self.read_text(path, max_chars=24_000)
            if content is None:
                continue
            parts.append(f"<file path={path!r}>\n{content}\n</file>")
        return "\n\n".join(parts)

    def validate_change(self, change: DeveloperFileChange) -> Path:
        relative = Path(change.path)
        if relative.is_absolute() or not change.path.strip():
            raise RepositoryError("absolute_or_empty_path_forbidden")
        if any(part in {".git", ".."} for part in relative.parts):
            raise RepositoryError("developer_path_forbidden")
        candidate = (self.root / relative).resolve(strict=False)
        if candidate != self.root and self.root not in candidate.parents:
            raise RepositoryError("developer_path_outside_repository")
        if candidate == self.root:
            raise RepositoryError("developer_path_invalid")
        if candidate.exists() and candidate.is_dir():
            raise RepositoryError("developer_target_is_directory")
        if change.operation == "create" and candidate.exists():
            raise RepositoryError("developer_create_target_exists")
        if change.operation == "replace" and not candidate.exists():
            raise RepositoryError("developer_replace_target_missing")
        return candidate

    def assert_applied_changes(self, changes: list[DeveloperFileChange]) -> None:
        for change in changes:
            path = self._resolve_existing_file(change.path)
            if path.stat().st_size > self.max_read_bytes:
                raise RepositoryError("developer_file_too_large")
            data = path.read_bytes()
            if b"\x00" in data[:4096]:
                raise RepositoryError("developer_binary_file_forbidden")
            try:
                content = data.decode("utf-8", errors="strict")
            except UnicodeDecodeError as exc:
                raise RepositoryError("developer_non_utf8_file") from exc
            if content != change.content:
                raise RepositoryError("developer_planned_content_changed:" + change.path)

    def read_text(self, relative_path: str, *, max_chars: int = 24_000) -> str | None:
        path = self._resolve_existing_file(relative_path)
        size = path.stat().st_size
        if size > self.max_read_bytes:
            return None
        data = path.read_bytes()
        if b"\x00" in data[:4096]:
            return None
        return data.decode("utf-8", errors="replace")[:max_chars]

    def proposed_diff(self, changes: list[DeveloperFileChange]) -> str:
        chunks: list[str] = []
        for change in changes:
            path = self.validate_change(change)
            old = ""
            if path.exists():
                if path.stat().st_size > self.max_read_bytes:
                    raise RepositoryError("developer_file_too_large")
                old = path.read_text(encoding="utf-8", errors="replace")
            diff = difflib.unified_diff(
                old.splitlines(keepends=True),
                change.content.splitlines(keepends=True),
                fromfile=f"a/{change.path}" if old else "/dev/null",
                tofile=f"b/{change.path}",
            )
            chunks.append("".join(diff))
        return "\n".join(chunk for chunk in chunks if chunk)

    async def create_branch(self, branch_name: str, *, base_branch: str) -> None:
        await self.verify()
        if not await self.is_clean():
            raise RepositoryError("developer_repository_dirty")
        current = await self.current_branch()
        if current != base_branch:
            await self._git("switch", base_branch)
        await self._git("switch", "-c", branch_name)

    def apply_changes(self, changes: list[DeveloperFileChange]) -> None:
        for change in changes:
            path = self.validate_change(change)
            path.parent.mkdir(parents=True, exist_ok=True)
            temp = path.with_name(path.name + ".lumi-tmp")
            temp.write_text(change.content, encoding="utf-8")
            os.replace(temp, path)

    async def diff(self) -> str:
        tracked = await self._git("diff", "--no-ext-diff", "--binary", "--")
        untracked_output = await self._git("ls-files", "--others", "--exclude-standard")
        chunks: list[str] = [tracked] if tracked.strip() else []
        for relative_path in [line for line in untracked_output.splitlines() if line]:
            path = self._resolve_existing_file(relative_path)
            if path.stat().st_size > self.max_read_bytes:
                raise RepositoryError("developer_file_too_large")
            data = path.read_bytes()
            if b"\x00" in data[:4096]:
                raise RepositoryError("developer_binary_file_forbidden")
            content = data.decode("utf-8", errors="strict")
            rendered = difflib.unified_diff(
                [],
                content.splitlines(keepends=True),
                fromfile="/dev/null",
                tofile=f"b/{relative_path}",
            )
            chunks.append("".join(rendered))
        return "\n".join(chunk for chunk in chunks if chunk)

    async def run_checks(self, checks: Iterable[str]) -> list[DeveloperCheckResult]:
        names = list(checks)
        if names and not self.allow_local_checks:
            return [
                DeveloperCheckResult(
                    name=name,
                    command=[],
                    status="skipped",
                    output="local_check_execution_disabled",
                )
                for name in names
            ]

        results: list[DeveloperCheckResult] = []
        for name in names:
            command, cwd = self._check_command(name)
            if command is None:
                results.append(DeveloperCheckResult(name=name, command=[], status="skipped", output="check_not_available"))
                continue
            try:
                code, output = await self._run(command, cwd=cwd, timeout=self.command_timeout_seconds)
                results.append(
                    DeveloperCheckResult(
                        name=name,
                        command=command,
                        status="passed" if code == 0 else "failed",
                        return_code=code,
                        output=output[-20_000:],
                    )
                )
            except asyncio.TimeoutError:
                results.append(
                    DeveloperCheckResult(
                        name=name,
                        command=command,
                        status="failed",
                        return_code=None,
                        output="check_timeout",
                    )
                )
        return results

    async def commit(self, paths: list[str], message: str) -> str:
        if not paths:
            raise RepositoryError("developer_no_changes_to_commit")
        for path in paths:
            self._resolve_candidate(path)
        await self._git("add", "--", *paths)
        await self._git("commit", "-m", message[:200])
        return (await self._git("rev-parse", "HEAD")).strip()

    async def push(self, branch_name: str) -> None:
        await self._git("push", "-u", "origin", branch_name, timeout=max(self.command_timeout_seconds, 300))

    def _resolve_existing_file(self, relative_path: str) -> Path:
        path = self._resolve_candidate(relative_path)
        if not path.exists() or not path.is_file():
            raise RepositoryError("developer_file_not_found")
        return path

    def _resolve_candidate(self, relative_path: str) -> Path:
        relative = Path(relative_path)
        if relative.is_absolute() or any(part in {".git", ".."} for part in relative.parts):
            raise RepositoryError("developer_path_forbidden")
        candidate = (self.root / relative).resolve(strict=False)
        if candidate != self.root and self.root not in candidate.parents:
            raise RepositoryError("developer_path_outside_repository")
        return candidate

    def _select_files(self, files: list[str], goal: str, *, max_files: int) -> list[str]:
        terms = {term for term in re.findall(r"[a-zA-Z0-9_\-]{3,}", goal.lower())}
        preferred_names = {"README.md", "pyproject.toml", "Package.swift", "docs/architecture.md"}
        scored: list[tuple[int, str]] = []
        for path in files:
            lowered = path.lower()
            score = sum(3 for term in terms if term in lowered)
            if path in preferred_names:
                score += 2
            if any(lowered.endswith(ext) for ext in (".py", ".swift", ".md", ".toml", ".json", ".yml", ".yaml")):
                score += 1
            scored.append((score, path))
        scored.sort(key=lambda item: (-item[0], item[1]))
        return [path for _, path in scored[: max(1, min(max_files, 12))]]

    def _check_command(self, name: str) -> tuple[list[str] | None, Path]:
        if name == "python-core-tests":
            target = self.root / "services/core/tests"
            if target.exists():
                return [sys.executable, "-B", "-m", "pytest", "-p", "no:cacheprovider", "services/core/tests", "-q"], self.root
        if name == "rag-regression":
            target = self.root / "scripts/eval_rag.py"
            if target.exists():
                return [sys.executable, "-B", "scripts/eval_rag.py", "--assert-thresholds"], self.root
        if name == "memory-regression":
            target = self.root / "scripts/eval_memory.py"
            if target.exists():
                return [sys.executable, "-B", "scripts/eval_memory.py", "--assert-thresholds"], self.root
        if name == "swift-tests":
            target = self.root / "apps/macos/Package.swift"
            if target.exists():
                return ["swift", "test"], self.root / "apps/macos"
        return None, self.root

    async def _git(self, *args: str, timeout: int | None = None) -> str:
        code, output = await self._run(["git", "-C", str(self.root), *args], cwd=self.root, timeout=timeout or self.command_timeout_seconds)
        if code != 0:
            raise RepositoryError("git_failed:" + output[-2_000:])
        return output

    @staticmethod
    async def _run(command: list[str], *, cwd: Path, timeout: int) -> tuple[int, str]:
        environment = dict(os.environ)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process = await asyncio.create_subprocess_exec(
            *command,
            cwd=str(cwd),
            env=environment,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        try:
            stdout, _ = await asyncio.wait_for(process.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            process.kill()
            await process.communicate()
            raise
        return process.returncode or 0, stdout.decode("utf-8", errors="replace")
