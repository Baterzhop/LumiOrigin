import asyncio

import pytest
from pydantic import BaseModel

from lumi_core.tools.builtins import Workspace, build_default_registry
from lumi_core.tools.policy import RiskLevel, ToolSpec
from lumi_core.tools.registry import RegisteredTool, ToolExecutionError, ToolRegistry


@pytest.mark.asyncio
async def test_workspace_read_is_sandboxed(tmp_path):
    workspace = Workspace(tmp_path / "workspace")
    (workspace.root / "note.txt").write_text("hello lumi", encoding="utf-8")
    registry = build_default_registry(workspace)

    result = await registry.execute("workspace.read_text", {"path": "note.txt"})
    assert result["content"] == "hello lumi"

    with pytest.raises(ToolExecutionError, match="path_outside_workspace"):
        await registry.execute("workspace.read_text", {"path": "../secret.txt"})


@pytest.mark.asyncio
async def test_workspace_rejects_malformed_arguments(tmp_path):
    registry = build_default_registry(Workspace(tmp_path / "workspace"))
    with pytest.raises(ToolExecutionError, match="invalid_arguments"):
        await registry.execute("workspace.read_text", {})


@pytest.mark.asyncio
async def test_registry_enforces_timeout():
    class Args(BaseModel):
        value: str = "x"

    async def slow(args: BaseModel):
        await asyncio.sleep(0.05)
        return {"ok": True}

    registry = ToolRegistry()
    registry.register(
        RegisteredTool(
            ToolSpec(name="slow", description="slow", risk=RiskLevel.low, timeout_seconds=0.01),
            Args,
            slow,
        )
    )
    with pytest.raises(ToolExecutionError, match="tool_timeout"):
        await registry.execute("slow", {})


def test_registry_exposes_json_schema(tmp_path):
    registry = build_default_registry(Workspace(tmp_path / "workspace"))
    read = next(spec for spec in registry.specs() if spec.name == "workspace.read_text")
    assert read.arguments_schema["type"] == "object"
    assert "path" in read.arguments_schema["properties"]
