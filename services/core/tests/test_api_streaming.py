from dataclasses import replace

from fastapi.testclient import TestClient

from lumi_core.agent.runtime import AgentRuntime
from lumi_core.api.main import create_app
from lumi_core.config import Settings
from lumi_core.models.gateway import ModelGateway, ModelMessage, ModelResult, ModelStreamEvent
from lumi_core.storage.database import Database


class FastStreamingProvider:
    provider_name = "fake"
    model_name = "api-stream"

    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        return ModelResult(content="hello", provider=self.provider_name, model=self.model_name)

    async def stream(self, messages, system_prompt, *, cancel_event=None):
        yield ModelStreamEvent(type="delta", delta="hel", provider=self.provider_name, model=self.model_name)
        yield ModelStreamEvent(type="delta", delta="lo", provider=self.provider_name, model=self.model_name)
        yield ModelStreamEvent(type="completed", provider=self.provider_name, model=self.model_name)


def test_http_sse_stream_emits_structured_lifecycle(monkeypatch, tmp_path):
    root = tmp_path / "sse-app"
    settings = replace(
        Settings.from_env(),
        database_path=root / "lumi.sqlite3",
        backup_dir=root / "backups",
        tool_workspace_root=root / "workspace",
        rag_dense_enabled=False,
        developer_repo_root=None,
        developer_github_repository=None,
        developer_github_token=None,
    )
    app = create_app(settings)
    database = Database(tmp_path / "stream-runtime.sqlite3")
    database.migrate()
    monkeypatch.setattr(
        app.state.lumi,
        "runtime",
        AgentRuntime(database, ModelGateway(FastStreamingProvider())),
    )

    client = TestClient(app)
    with client.stream("POST", "/v1/chat/stream", json={"message": "ping"}) as response:
        body = "".join(response.iter_text())

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")
    assert "event: started" in body
    assert "event: delta" in body
    assert "event: completed" in body
    assert '"content":"hello"' in body
    assert '"finish_reason":"stop"' in body
