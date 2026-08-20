from fastapi.testclient import TestClient

import lumi_core.api.main as api_main
from lumi_core.agent.planner import PlannerDecision, ScriptedPlanner
from lumi_core.agent.task_runtime import TaskRuntime
from lumi_core.storage.database import Database
from lumi_core.tools.builtins import Workspace, build_default_registry
from lumi_core.tools.policy import PolicyEngine


def test_agent_api_requires_and_records_write_approval(tmp_path, monkeypatch):
    database = Database(tmp_path / "agent-api.sqlite3")
    database.migrate()
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
                    arguments={"path": "api.txt", "content": "approved through api"},
                ),
                PlannerDecision(action="finish", answer="done"),
            ]
        ),
    )
    monkeypatch.setattr(api_main, "task_runtime", runtime)
    client = TestClient(api_main.app)

    created = client.post("/v1/tasks", json={"goal": "create api.txt"})
    assert created.status_code == 200
    task = created.json()
    assert task["status"] == "awaiting_approval"
    call = task["tool_calls"][0]
    assert call["arguments_preview"] == '{"content": "approved through api", "path": "api.txt"}'
    assert not (workspace.root / "api.txt").exists()

    approved = client.post(f"/v1/tool-calls/{call['id']}/approve")
    assert approved.status_code == 200
    assert approved.json()["status"] == "completed"
    assert (workspace.root / "api.txt").read_text(encoding="utf-8") == "approved through api"


def test_tools_endpoint_marks_write_as_high_risk():
    client = TestClient(api_main.app)
    response = client.get("/v1/tools")
    assert response.status_code == 200
    write = next(item for item in response.json()["tools"] if item["name"] == "workspace.write_text")
    assert write["risk"] == "high"
    assert write["side_effects"] is True
