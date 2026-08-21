import asyncio

from lumi_core.agent.generations import GenerationRegistry
from lumi_core.agent.runtime import AgentRuntime
from lumi_core.models.gateway import GenerationCancelled, ModelGateway, ModelMessage, ModelResult, ModelStreamEvent
from lumi_core.storage.database import Database


class StreamingProvider:
    provider_name = "fake"
    model_name = "stream-model"

    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        return ModelResult(content="hello", provider=self.provider_name, model=self.model_name)

    async def stream(self, messages, system_prompt, *, cancel_event=None):
        for token in ["hel", "lo"]:
            if cancel_event is not None and cancel_event.is_set():
                raise GenerationCancelled()
            yield ModelStreamEvent(type="delta", delta=token, provider=self.provider_name, model=self.model_name)
        yield ModelStreamEvent(type="completed", provider=self.provider_name, model=self.model_name)


async def test_runtime_stream_persists_completed_message(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    runtime = AgentRuntime(db, ModelGateway(StreamingProvider()))
    cancel = asyncio.Event()

    events = [
        event
        async for event in runtime.stream_chat(
            "ping",
            generation_id="generation-1",
            cancel_event=cancel,
        )
    ]

    assert [event.type for event in events] == ["started", "delta", "delta", "completed"]
    assert events[-1].content == "hello"
    messages = db.list_messages(events[-1].conversation_id)
    assert [message["content"] for message in messages] == ["ping", "hello"]
    assert messages[-1]["generation_id"] == "generation-1"
    assert messages[-1]["finish_reason"] == "stop"


async def test_runtime_stream_cancel_preserves_visible_partial(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    runtime = AgentRuntime(db, ModelGateway(StreamingProvider()))
    cancel = asyncio.Event()
    events = []

    async for event in runtime.stream_chat(
        "ping",
        generation_id="generation-2",
        cancel_event=cancel,
    ):
        events.append(event)
        if event.type == "delta":
            cancel.set()

    assert events[-1].type == "cancelled"
    assert events[-1].content == "hel"
    messages = db.list_messages(events[-1].conversation_id)
    assert messages[-1]["content"] == "hel"
    assert messages[-1]["finish_reason"] == "cancelled"


async def test_generation_registry_cancel_and_release():
    registry = GenerationRegistry()
    handle = await registry.create()
    assert await registry.active_count() == 1
    assert await registry.cancel(handle.generation_id) is True
    assert handle.cancel_event.is_set()
    await registry.release(handle.generation_id)
    assert await registry.active_count() == 0
    assert await registry.cancel(handle.generation_id) is False
