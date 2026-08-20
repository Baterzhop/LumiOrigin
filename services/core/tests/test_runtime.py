from lumi_core.agent.runtime import AgentRuntime
from lumi_core.models.gateway import ModelMessage, ModelResult, ModelGateway
from lumi_core.storage.database import Database


class FakeProvider:
    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        assert "local-first" in system_prompt
        return ModelResult(content="pong", provider="fake", model="fake-model")


async def test_runtime_persists_chat(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    runtime = AgentRuntime(db, ModelGateway(FakeProvider()))

    reply = await runtime.chat("ping")
    messages = db.list_messages(reply.conversation_id)

    assert reply.content == "pong"
    assert reply.provider == "fake"
    assert [m["content"] for m in messages] == ["ping", "pong"]
