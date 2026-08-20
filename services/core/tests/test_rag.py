from lumi_core.rag.embeddings import HashEmbeddingProvider
from lumi_core.rag.eval import ndcg_at_k, recall_at_k, reciprocal_rank
from lumi_core.rag.ingestion import IngestionService
from lumi_core.rag.retrieval import HybridRetriever
from lumi_core.storage.database import Database


async def test_ingestion_deduplicates_and_builds_sparse_dense_indexes(tmp_path):
    db = Database(tmp_path / "lumi.sqlite3")
    db.migrate()
    embedder = HashEmbeddingProvider(dimensions=32)
    service = IngestionService(db, embedder=embedder, embedding_model="hash-test", chunk_words=80, overlap_words=10)

    data = b"Ducati Monster oil drain plug torque is twenty newton metres. Engine service manual reference."
    first = await service.ingest_bytes(filename="manual.txt", data=data)
    second = await service.ingest_bytes(filename="copy.txt", data=data)

    assert first.deduplicated is False
    assert second.deduplicated is True
    assert first.document_id == second.document_id
    assert first.chunk_count == 1
    assert db.embedding_count(first.document_id, "hash-test") == 1

    retriever = HybridRetriever(db, embedder=embedder, embedding_model="hash-test")
    hits = await retriever.retrieve("Ducati drain plug torque", k=3)
    assert hits
    assert hits[0].document_id == first.document_id
    assert "fts5" in hits[0].retrieval


def test_rag_metrics_are_correct():
    retrieved = ["c", "a", "b"]
    relevant = {"a", "b"}
    assert recall_at_k(retrieved, relevant, 2) == 0.5
    assert reciprocal_rank(retrieved, relevant) == 0.5
    score = ndcg_at_k(retrieved, {"a": 3.0, "b": 1.0}, 3)
    assert 0.0 < score < 1.0
