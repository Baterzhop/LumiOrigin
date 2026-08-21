from fastapi.testclient import TestClient

from lumi_core.agent.runtime import AgentRuntime
from lumi_core.api import main as api_main
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
    database = Database(tmp_path / "lumi.sqlite3")
    database.migrate()
    services = api_main.app.state.lumi
    monkeypatch.setattr(
        services,
        "runtime",
        AgentRuntime(database, ModelGateway(FastStreamingProvider())),
    )

    client = TestClient(api_main.app)
    with client.stream("POST", "/v1/chat/stream", json={"message": "ping"}) as response:
        body = "".join(response.iter_text())

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/event-stream")
    assert "event: started" in body
    assert "event: delta" in body
    assert "event: completed" in body
    assert '"content":"hello"' in body
    assert '"finish_reason":"stop"' in body
