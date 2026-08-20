from lumi_core.memory import MemoryService, MemoryStore
from lumi_core.rag.embeddings import HashEmbeddingProvider
from lumi_core.storage.database import Database


async def test_memory_create_search_update_delete(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    store = MemoryStore(db)
    service = MemoryService(
        store,
        embedder=HashEmbeddingProvider(dimensions=64),
        embedding_model="test-hash-v1",
    )

    created = await service.create(
        "The preferred project language is Swift for native macOS UI.",
        kind="preference",
        title="Native UI language",
    )
    assert created["approved"] is True
    assert len(service.list()) == 1

    hits = await service.search("Swift macOS project", k=3)
    assert hits
    assert hits[0].memory_id == created["id"]
    assert hits[0].retrieval

    updated = await service.update(
        created["id"],
        content="The preferred project language is SwiftUI for the native macOS client.",
    )
    assert updated is not None
    assert "SwiftUI" in updated["content"]

    assert service.delete(created["id"]) is True
    assert store.get(created["id"]) is None
    assert service.list() == []
    assert await service.search("SwiftUI macOS", k=3) == []
    assert store.list_embeddings("test-hash-v1") == []


def test_memory_store_hard_delete_removes_fts_row(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    store = MemoryStore(db)
    item = store.create(content="Permanent deletion probe zebra-991", kind="note")
    assert store.sparse_search("zebra-991")
    assert store.delete(item["id"]) is True
    assert store.sparse_search("zebra-991") == []
