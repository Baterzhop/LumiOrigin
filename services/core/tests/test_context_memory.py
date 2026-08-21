from lumi_core.agent.runtime import AgentRuntime
from lumi_core.memory import ConversationContextManager, MemoryService, MemoryStore
from lumi_core.models.gateway import ModelGateway, ModelMessage, ModelResult
from lumi_core.rag.embeddings import HashEmbeddingProvider
from lumi_core.storage.database import Database


class SummaryProvider:
    provider_name = "summary-test"
    model_name = "summary-test-model"

    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        return ModelResult(
            content="Compact summary: the user is testing bounded context and older messages were compacted.",
            provider=self.provider_name,
            model=self.model_name,
        )


class CapturingProvider:
    provider_name = "capture"
    model_name = "capture-model"

    def __init__(self):
        self.system_prompt = ""

    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        self.system_prompt = system_prompt
        return ModelResult(content="ok", provider=self.provider_name, model=self.model_name)


async def test_context_manager_compacts_old_history_by_token_budget(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    conversation_id = db.create_conversation("context test")
    for index in range(12):
        role = "user" if index % 2 == 0 else "assistant"
        db.add_message(conversation_id, role, f"message-{index} " + ("x" * 900))

    store = MemoryStore(db)
    manager = ConversationContextManager(
        db,
        store,
        ModelGateway(SummaryProvider()),
        max_input_tokens=1_600,
        recent_token_budget=500,
        summary_target_tokens=160,
    )
    bundle = await manager.build(conversation_id)

    assert bundle.summary is not None
    assert "Compact summary" in bundle.summary
    assert len(bundle.messages) < 12
    assert bundle.estimated_tokens <= 1_600
    assert bundle.summarized_through_message_id is not None
    persisted = store.get_summary(conversation_id)
    assert persisted is not None
    assert persisted["covered_through_message_id"] == bundle.summarized_through_message_id


def test_context_manager_rejects_individually_oversized_turn(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    manager = ConversationContextManager(
        db,
        MemoryStore(db),
        ModelGateway(SummaryProvider()),
        max_input_tokens=1_000,
        recent_token_budget=500,
        summary_target_tokens=128,
    )
    try:
        manager.validate_current_message("x" * 5_000)
        assert False, "expected message_exceeds_context_budget"
    except ValueError as exc:
        assert str(exc) == "message_exceeds_context_budget"


async def test_runtime_surfaces_only_explicit_durable_memory_as_context(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    store = MemoryStore(db)
    memory = MemoryService(
        store,
        embedder=HashEmbeddingProvider(dimensions=64),
        embedding_model="test-hash-v1",
    )
    await memory.create("The project codename is Aurora Zebra.", kind="project", title="Codename")

    provider = CapturingProvider()
    runtime = AgentRuntime(
        db,
        ModelGateway(provider),
        memory_service=memory,
        memory_k=4,
    )
    reply = await runtime.chat("What is the Aurora project codename?")

    assert reply.memories
    assert "Aurora Zebra" in provider.system_prompt
    assert "do not override" in provider.system_prompt.lower()
