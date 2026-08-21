from __future__ import annotations

import math

from lumi_core.rag.contracts import RetrievedChunk
from lumi_core.rag.embeddings import EmbeddingProvider
from lumi_core.rag.rerank import Reranker
from lumi_core.storage.database import Database


class HybridRetriever:
    def __init__(
        self,
        database: Database,
        *,
        embedder: EmbeddingProvider | None = None,
        embedding_model: str | None = None,
        reranker: Reranker | None = None,
        rrf_k: int = 60,
        sparse_weight: float = 0.55,
        dense_weight: float = 0.45,
    ):
        self.database = database
        self.embedder = embedder
        self.embedding_model = embedding_model
        self.reranker = reranker
        self.rrf_k = max(1, rrf_k)
        self.sparse_weight = sparse_weight
        self.dense_weight = dense_weight

    async def retrieve(self, query: str, *, k: int = 6) -> list[RetrievedChunk]:
        k = max(1, min(k, 20))
        candidate_k = max(20, k * 5)
        sparse = self.database.search_chunks_fts(query, candidate_k)
        dense = await self._dense(query, candidate_k)

        candidates: dict[str, dict] = {}
        scores: dict[str, float] = {}
        modes: dict[str, set[str]] = {}

        for rank, item in enumerate(sparse, start=1):
            chunk_id = item["chunk_id"]
            candidates[chunk_id] = item
            scores[chunk_id] = scores.get(chunk_id, 0.0) + self.sparse_weight / (self.rrf_k + rank)
            modes.setdefault(chunk_id, set()).add("fts5")

        for rank, item in enumerate(dense, start=1):
            chunk_id = item["chunk_id"]
            candidates[chunk_id] = item
            scores[chunk_id] = scores.get(chunk_id, 0.0) + self.dense_weight / (self.rrf_k + rank)
            modes.setdefault(chunk_id, set()).add("dense")

        fused = sorted(scores, key=scores.get, reverse=True)[: max(k, 12)]
        chunks = [
            RetrievedChunk(
                chunk_id=chunk_id,
                document_id=candidates[chunk_id]["document_id"],
                title=candidates[chunk_id].get("title"),
                source=candidates[chunk_id].get("source"),
                text=candidates[chunk_id]["text"],
                score=scores[chunk_id],
                page=candidates[chunk_id].get("page"),
                section=candidates[chunk_id].get("section"),
                retrieval=sorted(modes.get(chunk_id, set())),
            )
            for chunk_id in fused
        ]
        if self.reranker and chunks:
            try:
                chunks = await self.reranker.rerank(query, chunks)
            except Exception:
                pass
        return chunks[:k]

    async def _dense(self, query: str, limit: int) -> list[dict]:
        if self.embedder is None or not self.embedding_model:
            return []
        rows = self.database.list_embeddings(self.embedding_model)
        if not rows:
            return []
        try:
            query_vector = (await self.embedder.embed([query]))[0]
        except Exception:
            return []
        scored: list[tuple[float, dict]] = []
        for row in rows:
            vector = row["vector"]
            if len(vector) != len(query_vector):
                continue
            score = self._cosine(query_vector, vector)
            scored.append((score, row))
        scored.sort(key=lambda pair: pair[0], reverse=True)
        return [row for _, row in scored[:limit]]

    @staticmethod
    def _cosine(a: list[float], b: list[float]) -> float:
        dot = sum(x * y for x, y in zip(a, b, strict=True))
        norm_a = math.sqrt(sum(x * x for x in a))
        norm_b = math.sqrt(sum(y * y for y in b))
        if norm_a == 0 or norm_b == 0:
            return 0.0
        return dot / (norm_a * norm_b)
