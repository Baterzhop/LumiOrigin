import pytest

from lumi_core.agent.planner import PlannerDecision, ScriptedPlanner
from lumi_core.agent.task_runtime import TaskRuntime
from lumi_core.storage.database import Database
from lumi_core.tools.builtins import Workspace, build_default_registry
from lumi_core.tools.policy import PolicyEngine


@pytest.fixture
def database(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    return db


@pytest.mark.asyncio
async def test_read_only_tool_runs_without_approval(database, tmp_path):
    workspace = Workspace(tmp_path / "workspace")
    (workspace.root / "note.txt").write_text("alpha beta", encoding="utf-8")
    runtime = TaskRuntime(
        database,
        build_default_registry(workspace),
        PolicyEngine(),
        ScriptedPlanner(
            [
                PlannerDecision(action="tool", tool="workspace.read_text", arguments={"path": "note.txt"}),
                PlannerDecision(action="finish", answer="done"),
            ]
        ),
    )

    task = await runtime.create_and_run("read the note")
    assert task["status"] == "completed"
    assert task["result_text"] == "done"
    assert task["tool_calls"][0]["status"] == "completed"
    assert task["tool_calls"][0]["result"]["content"] == "alpha beta"


@pytest.mark.asyncio
async def test_write_tool_requires_explicit_approval(database, tmp_path):
    workspace = Workspace(tmp_path / "workspace")
    runtime = TaskRuntime(
        database,
        build_default_registry(workspace),
        PolicyEngine(),
        ScriptedPlanner(
            [
                PlannerDecision(
                    action="tool",
                    tool="workspace.write_text",
                    arguments={"path": "created.txt", "content": "approved"},
                ),
                PlannerDecision(action="finish", answer="written"),
            ]
        ),
    )

    task = await runtime.create_and_run("create a file")
    assert task["status"] == "awaiting_approval"
    call = task["tool_calls"][0]
    assert call["status"] == "awaiting_approval"
    assert not (workspace.root / "created.txt").exists()

    finished = await runtime.approve(call["id"])
    assert finished["status"] == "completed"
    assert (workspace.root / "created.txt").read_text(encoding="utf-8") == "approved"
    assert finished["tool_calls"][0]["status"] == "completed"


@pytest.mark.asyncio
async def test_user_can_deny_side_effect_and_planner_can_finish(database, tmp_path):
    workspace = Workspace(tmp_path / "workspace")
    runtime = TaskRuntime(
        database,
        build_default_registry(workspace),
        PolicyEngine(),
        ScriptedPlanner(
            [
                PlannerDecision(
                    action="tool",
                    tool="workspace.write_text",
                    arguments={"path": "blocked.txt", "content": "no"},
                ),
                PlannerDecision(action="finish", answer="respected denial"),
            ]
        ),
    )

    waiting = await runtime.create_and_run("write if allowed")
    denied = await runtime.deny(waiting["tool_calls"][0]["id"])
    assert denied["status"] == "completed"
    assert denied["tool_calls"][0]["status"] == "denied"
    assert denied["tool_calls"][0]["error"] == "user_denied"
    assert not (workspace.root / "blocked.txt").exists()


@pytest.mark.asyncio
async def test_step_budget_stops_run(database, tmp_path):
    runtime = TaskRuntime(
        database,
        build_default_registry(Workspace(tmp_path / "workspace")),
        PolicyEngine(),
        ScriptedPlanner(
            [
                PlannerDecision(action="tool", tool="workspace.list_files", arguments={}),
                PlannerDecision(action="tool", tool="workspace.list_files", arguments={}),
            ]
        ),
    )
    task = await runtime.create_and_run("loop", max_steps=1)
    assert task["status"] == "budget_exceeded"
    assert task["error"] == "step_budget_exceeded"
