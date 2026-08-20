from __future__ import annotations

import fnmatch
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field

from lumi_core.rag.contracts import Retriever

from .policy import RiskLevel, ToolSpec
from .registry import RegisteredTool, ToolExecutionError, ToolRegistry


class Workspace:
    def __init__(self, root: Path, *, max_read_bytes: int = 512_000):
        self.root = root.expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.max_read_bytes = max(4_096, max_read_bytes)

    def resolve(self, relative: str) -> Path:
        if Path(relative).is_absolute():
            raise ToolExecutionError("absolute_paths_forbidden")
        candidate = (self.root / relative).resolve()
        if candidate != self.root and self.root not in candidate.parents:
            raise ToolExecutionError("path_outside_workspace")
        return candidate


class ListFilesArgs(BaseModel):
    path: str = "."
    recursive: bool = False
    limit: int = Field(default=100, ge=1, le=500)


class ReadTextArgs(BaseModel):
    path: str
    max_chars: int = Field(default=20_000, ge=1, le=100_000)


class SearchTextArgs(BaseModel):
    query: str = Field(min_length=1, max_length=1_000)
    path: str = "."
    pattern: str = "*"
    limit: int = Field(default=50, ge=1, le=200)


class WriteTextArgs(BaseModel):
    path: str
    content: str = Field(max_length=200_000)
    overwrite: bool = False


class KnowledgeSearchArgs(BaseModel):
    query: str = Field(min_length=1, max_length=20_000)
    k: int = Field(default=6, ge=1, le=12)


def build_default_registry(workspace: Workspace, retriever: Retriever | None = None) -> ToolRegistry:
    registry = ToolRegistry()

    async def list_files(args: BaseModel) -> Any:
        value = ListFilesArgs.model_validate(args.model_dump())
        base = workspace.resolve(value.path)
        if not base.exists():
            raise ToolExecutionError("path_not_found")
        if not base.is_dir():
            raise ToolExecutionError("not_a_directory")
        iterator = base.rglob("*") if value.recursive else base.iterdir()
        entries: list[dict] = []
        for item in iterator:
            if len(entries) >= value.limit:
                break
            try:
                resolved = item.resolve()
            except OSError:
                continue
            if resolved != workspace.root and workspace.root not in resolved.parents:
                continue
            entries.append(
                {
                    "path": str(item.relative_to(workspace.root)),
                    "kind": "directory" if item.is_dir() else "file",
                    "size": item.stat().st_size if item.is_file() else None,
                }
            )
        return {"root": str(workspace.root), "entries": entries, "truncated": len(entries) >= value.limit}

    async def read_text(args: BaseModel) -> Any:
        value = ReadTextArgs.model_validate(args.model_dump())
        path = workspace.resolve(value.path)
        if not path.exists():
            raise ToolExecutionError("path_not_found")
        if not path.is_file():
            raise ToolExecutionError("not_a_file")
        size = path.stat().st_size
        if size > workspace.max_read_bytes:
            raise ToolExecutionError("file_too_large")
        text = path.read_text(encoding="utf-8", errors="replace")
        clipped = text[: value.max_chars]
        return {"path": value.path, "content": clipped, "truncated": len(clipped) < len(text), "size": size}

    async def search_text(args: BaseModel) -> Any:
        value = SearchTextArgs.model_validate(args.model_dump())
        base = workspace.resolve(value.path)
        if not base.exists() or not base.is_dir():
            raise ToolExecutionError("path_not_found")
        query = value.query.casefold()
        matches: list[dict] = []
        scanned = 0
        for path in base.rglob("*"):
            if len(matches) >= value.limit or scanned >= 2_000:
                break
            if not path.is_file() or not fnmatch.fnmatch(path.name, value.pattern):
                continue
            scanned += 1
            try:
                resolved = path.resolve()
                if resolved != workspace.root and workspace.root not in resolved.parents:
                    continue
                if path.stat().st_size > workspace.max_read_bytes:
                    continue
                for line_number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
                    if query in line.casefold():
                        matches.append(
                            {
                                "path": str(path.relative_to(workspace.root)),
                                "line": line_number,
                                "text": line[:500],
                            }
                        )
                        if len(matches) >= value.limit:
                            break
            except (OSError, UnicodeError):
                continue
        return {"query": value.query, "matches": matches, "scanned_files": scanned}

    async def write_text(args: BaseModel) -> Any:
        value = WriteTextArgs.model_validate(args.model_dump())
        path = workspace.resolve(value.path)
        if path == workspace.root:
            raise ToolExecutionError("invalid_target")
        if path.exists() and path.is_dir():
            raise ToolExecutionError("target_is_directory")
        if path.exists() and not value.overwrite:
            raise ToolExecutionError("target_exists")
        parent = path.parent.resolve()
        if parent != workspace.root and workspace.root not in parent.parents:
            raise ToolExecutionError("path_outside_workspace")
        parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value.content, encoding="utf-8")
        return {"path": str(path.relative_to(workspace.root)), "bytes": len(value.content.encode("utf-8")), "overwritten": value.overwrite}

    registry.register(
        RegisteredTool(
            ToolSpec(
                name="workspace.list_files",
                description="List files inside Lumi's configured workspace. Read-only and sandboxed to the workspace root.",
                risk=RiskLevel.low,
                side_effects=False,
                timeout_seconds=5,
            ),
            ListFilesArgs,
            list_files,
        )
    )
    registry.register(
        RegisteredTool(
            ToolSpec(
                name="workspace.read_text",
                description="Read a UTF-8 text file inside Lumi's configured workspace with strict size and path limits.",
                risk=RiskLevel.low,
                side_effects=False,
                timeout_seconds=5,
            ),
            ReadTextArgs,
            read_text,
        )
    )
    registry.register(
        RegisteredTool(
            ToolSpec(
                name="workspace.search_text",
                description="Search text files inside Lumi's configured workspace. Read-only; never searches outside the sandbox root.",
                risk=RiskLevel.low,
                side_effects=False,
                timeout_seconds=8,
            ),
            SearchTextArgs,
            search_text,
        )
    )
    registry.register(
        RegisteredTool(
            ToolSpec(
                name="workspace.write_text",
                description="Create or overwrite a text file inside Lumi's workspace. This changes local state and always requires approval.",
                risk=RiskLevel.high,
                side_effects=True,
                timeout_seconds=5,
            ),
            WriteTextArgs,
            write_text,
        )
    )

    if retriever is not None:
        async def knowledge_search(args: BaseModel) -> Any:
            value = KnowledgeSearchArgs.model_validate(args.model_dump())
            hits = await retriever.retrieve(value.query, k=value.k)
            return {"query": value.query, "hits": [hit.model_dump() for hit in hits]}

        registry.register(
            RegisteredTool(
                ToolSpec(
                    name="knowledge.search",
                    description="Search Lumi's indexed local knowledge and return grounded chunks with source metadata.",
                    risk=RiskLevel.low,
                    side_effects=False,
                    timeout_seconds=20,
                ),
                KnowledgeSearchArgs,
                knowledge_search,
            )
        )

    return registry
