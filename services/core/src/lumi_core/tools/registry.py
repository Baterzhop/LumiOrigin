from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from typing import Any

from pydantic import BaseModel, ValidationError

from .policy import ToolSpec


class ToolExecutionError(Exception):
    pass


ToolExecutor = Callable[[BaseModel], Awaitable[Any]]


class RegisteredTool:
    def __init__(self, spec: ToolSpec, arguments_model: type[BaseModel], executor: ToolExecutor):
        self.spec = spec.model_copy(update={"arguments_schema": arguments_model.model_json_schema()})
        self.arguments_model = arguments_model
        self.executor = executor

    async def execute(self, arguments: dict[str, Any]) -> Any:
        try:
            validated = self.arguments_model.model_validate(arguments)
        except ValidationError as exc:
            raise ToolExecutionError("invalid_arguments") from exc
        try:
            return await asyncio.wait_for(self.executor(validated), timeout=self.spec.timeout_seconds)
        except TimeoutError as exc:
            raise ToolExecutionError("tool_timeout") from exc
        except ToolExecutionError:
            raise
        except Exception as exc:
            raise ToolExecutionError(type(exc).__name__) from exc


class ToolRegistry:
    def __init__(self):
        self._tools: dict[str, RegisteredTool] = {}

    def register(self, tool: RegisteredTool) -> None:
        if tool.spec.name in self._tools:
            raise ValueError(f"duplicate_tool:{tool.spec.name}")
        self._tools[tool.spec.name] = tool

    def get(self, name: str) -> RegisteredTool | None:
        return self._tools.get(name)

    def specs(self) -> list[ToolSpec]:
        return [self._tools[name].spec for name in sorted(self._tools)]

    async def execute(self, name: str, arguments: dict[str, Any]) -> Any:
        tool = self.get(name)
        if tool is None:
            raise ToolExecutionError("unknown_tool")
        return await tool.execute(arguments)
