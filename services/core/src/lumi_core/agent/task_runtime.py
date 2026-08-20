from __future__ import annotations

from datetime import datetime, timezone
import json
from typing import Any

from lumi_core.storage.database import Database
from lumi_core.tools.policy import PolicyEngine
from lumi_core.tools.registry import ToolExecutionError, ToolRegistry

from .planner import TaskPlanner


TERMINAL_TASK_STATES = {"completed", "failed", "denied", "budget_exceeded"}


class TaskRuntime:
    def __init__(self, database: Database, registry: ToolRegistry, policy: PolicyEngine, planner: TaskPlanner):
        self.database = database
        self.registry = registry
        self.policy = policy
        self.planner = planner

    async def create_and_run(
        self,
        goal: str,
        *,
        conversation_id: str | None = None,
        max_steps: int = 8,
        max_tool_calls: int = 6,
        max_seconds: int = 120,
    ) -> dict:
        clean = goal.strip()
        if not clean:
            raise ValueError("empty_goal")
        task_id = self.database.create_task(
            clean,
            conversation_id=conversation_id,
            max_steps=max(1, min(max_steps, 20)),
            max_tool_calls=max(0, min(max_tool_calls, 20)),
            max_seconds=max(5, min(max_seconds, 600)),
        )
        return await self.run_until_blocked(task_id)

    async def run_until_blocked(self, task_id: str) -> dict:
        while True:
            task = self.database.get_task(task_id)
            if task is None:
                raise ValueError("task_not_found")
            if task["status"] in TERMINAL_TASK_STATES or task["status"] == "awaiting_approval":
                return self.snapshot(task_id)
            if self._expired(task):
                self.database.update_task(task_id, status="budget_exceeded", error="time_budget_exceeded")
                return self.snapshot(task_id)
            if int(task["step_count"]) >= int(task["max_steps"]):
                self.database.update_task(task_id, status="budget_exceeded", error="step_budget_exceeded")
                return self.snapshot(task_id)

            next_step = int(task["step_count"]) + 1
            self.database.update_task(task_id, status="planning", step_count=next_step)
            observations = self._observations(task_id)
            try:
                decision = await self.planner.plan(
                    goal=task["goal"],
                    tools=self.registry.specs(),
                    observations=observations,
                    step=next_step,
                )
            except Exception as exc:
                self.database.update_task(task_id, status="failed", error=f"planner:{type(exc).__name__}")
                return self.snapshot(task_id)

            if decision.action == "finish":
                self.database.update_task(task_id, status="completed", result_text=decision.answer or "")
                return self.snapshot(task_id)

            tool = self.registry.get(decision.tool or "")
            if tool is None:
                self.database.create_tool_call(
                    task_id,
                    decision.tool or "",
                    decision.arguments,
                    risk="unknown",
                    status="failed",
                    decision_reason=decision.reason,
                    error="unknown_tool",
                )
                continue

            if self.database.count_tool_calls(task_id) >= int(task["max_tool_calls"]):
                self.database.update_task(task_id, status="budget_exceeded", error="tool_budget_exceeded")
                return self.snapshot(task_id)

            policy = self.policy.evaluate(tool.spec)
            status = "awaiting_approval" if policy.requires_confirmation else ("approved" if policy.allowed else "denied")
            call_id = self.database.create_tool_call(
                task_id,
                tool.spec.name,
                decision.arguments,
                risk=tool.spec.risk.value,
                status=status,
                decision_reason=policy.reason if decision.reason is None else f"{policy.reason}; {decision.reason}",
            )

            if policy.requires_confirmation:
                self.database.update_task(task_id, status="awaiting_approval", waiting_tool_call_id=call_id)
                return self.snapshot(task_id)
            if not policy.allowed:
                self.database.update_tool_call(call_id, status="denied", error=policy.reason)
                self.database.update_task(task_id, status="denied", error=policy.reason)
                return self.snapshot(task_id)

            await self._execute(call_id)
            self.database.update_task(task_id, status="running", waiting_tool_call_id=None)

    async def approve(self, tool_call_id: str) -> dict:
        call = self.database.get_tool_call(tool_call_id)
        if call is None:
            raise ValueError("tool_call_not_found")
        if call["status"] != "awaiting_approval":
            raise ValueError("tool_call_not_awaiting_approval")
        tool = self.registry.get(call["tool_name"])
        if tool is None:
            raise ValueError("unknown_tool")
        decision = self.policy.evaluate(tool.spec, user_confirmed=True)
        if not decision.allowed:
            self.database.update_tool_call(tool_call_id, status="denied", error=decision.reason)
            self.database.update_task(call["task_id"], status="denied", error=decision.reason, waiting_tool_call_id=None)
            return self.snapshot(call["task_id"])
        self.database.update_tool_call(tool_call_id, status="approved", decision_reason=decision.reason)
        self.database.update_task(call["task_id"], status="running", waiting_tool_call_id=None)
        await self._execute(tool_call_id)
        return await self.run_until_blocked(call["task_id"])

    async def deny(self, tool_call_id: str) -> dict:
        call = self.database.get_tool_call(tool_call_id)
        if call is None:
            raise ValueError("tool_call_not_found")
        if call["status"] != "awaiting_approval":
            raise ValueError("tool_call_not_awaiting_approval")
        self.database.update_tool_call(tool_call_id, status="denied", error="user_denied")
        self.database.update_task(call["task_id"], status="running", waiting_tool_call_id=None)
        return await self.run_until_blocked(call["task_id"])

    async def _execute(self, tool_call_id: str) -> None:
        call = self.database.get_tool_call(tool_call_id)
        if call is None:
            raise ValueError("tool_call_not_found")
        self.database.update_tool_call(tool_call_id, status="running", started=True)
        try:
            result = await self.registry.execute(call["tool_name"], call["arguments"])
            self.database.update_tool_call(tool_call_id, status="completed", result=result, finished=True)
        except ToolExecutionError as exc:
            self.database.update_tool_call(tool_call_id, status="failed", error=str(exc), finished=True)

    def snapshot(self, task_id: str) -> dict:
        task = self.database.get_task(task_id)
        if task is None:
            raise ValueError("task_not_found")
        result = dict(task)
        calls = self.database.list_tool_calls(task_id)
        for item in calls:
            item["arguments_preview"] = json.dumps(item.get("arguments") or {}, ensure_ascii=False, sort_keys=True)[:2_000]
            if item.get("result") is not None:
                item["result_preview"] = json.dumps(item["result"], ensure_ascii=False, sort_keys=True)[:2_000]
            else:
                item["result_preview"] = None
        result["tool_calls"] = calls
        return result

    def _observations(self, task_id: str) -> list[dict[str, Any]]:
        observations: list[dict[str, Any]] = []
        for item in self.database.list_tool_calls(task_id):
            observations.append(
                {
                    "tool": item["tool_name"],
                    "status": item["status"],
                    "result": item.get("result"),
                    "error": item.get("error"),
                }
            )
        return observations

    @staticmethod
    def _expired(task: dict) -> bool:
        deadline = task.get("deadline_at")
        if not deadline:
            return False
        try:
            return datetime.now(timezone.utc) >= datetime.fromisoformat(deadline)
        except ValueError:
            return True
