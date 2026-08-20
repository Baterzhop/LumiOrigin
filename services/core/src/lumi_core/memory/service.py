from __future__ import annotations

import math
from typing import Any

from pydantic import BaseModel, Field

from lumi_core.rag.embeddings import EmbeddingProvider

from .store import MemoryStore


class MemoryHit(BaseModel):
    memory_id: str
    kind: str
    title: str | None = None
    content: str
    source: str
    score: float
    retrieval: list[str] = Field(default_factory=list)


class MemoryService:
    def __init__(
        self,
        store: MemoryStore,
        *,
        embedder: EmbeddingProvider | None = None,
        embedding_model: str | None = None,
    ):
        self.store = store
        self.embedder = embedder
        self.embedding_model = embedding_model if embedder is not None else None

    async def create(
        self,
        content: str,
        *,
        kind: str = "fact",
        title: str | None = None,
        source: str = "user",
        metadata: dict[str, Any] | None = None,
    ) -> dict:
        clean = content.strip()
        if not clean:
            raise ValueError("empty_memory")
        record = self.store.create(
            content=clean,
            kind=kind.strip() or "fact",
            title=title.strip() if title and title.strip() else None,
            source=source,
            metadata=metadata,
            approved=True,
        )
        await self._embed_record(record)
        return self.store.get(record["id"]) or record

    async def update(
        self,
        memory_id: str,
        *,
        content: str | None = None,
        title: str | None = None,
        kind: str | None = None,
    ) -> dict | None:
        if content is not None and not content.strip():
            raise ValueError("empty_memory")
        record = self.store.update(
            memory_id,
            content=content.strip() if content is not None else None,
            title=title.strip() if title and title.strip() else ("" if title == "" else None),
            kind=kind.strip() if kind is not None else None,
        )
        if record is None:
            return None
        await self._embed_record(record)
        return self.store.get(memory_id)

    def list(self, limit: int = 100) -> list[dict]:
        return self.store.list(limit=limit, approved_only=True)

    def delete(self, memory_id: str) -> bool:
        return self.store.delete(memory_id)

    async def search(self, query: str, *, k: int = 4) -> list[MemoryHit]:
        clean = query.strip()
        if not clean:
            return []
        k = max(1, min(k, 20))
        sparse = self.store.sparse_search(clean, limit=max(20, k * 4))
        dense: list[dict] = []

        if self.embedder is not None and self.embedding_model:
            try:
                query_vectors = await self.embedder.embed([clean])
                if query_vectors and query_vectors[0]:
                    query_vector = query_vectors[0]
                    for item in self.store.list_embeddings(self.embedding_model):
                        score = _cosine(query_vector, item["vector"])
                        dense.append({**item, "dense_score": score})
                    dense.sort(key=lambda item: item["dense_score"], reverse=True)
                    dense = dense[: max(20, k * 4)]
            except Exception:
                dense = []

        fused: dict[str, dict] = {}
        rrf_k = 60.0
        for rank, item in enumerate(sparse, start=1):
            memory_id = item["memory_id"]
            target = fused.setdefault(memory_id, {**item, "score": 0.0, "retrieval": []})
            target["score"] += 0.62 / (rrf_k + rank)
            target["retrieval"].append("fts5")

        for rank, item in enumerate(dense, start=1):
            memory_id = item["memory_id"]
            target = fused.setdefault(memory_id, {**item, "score": 0.0, "retrieval": []})
            target["score"] += 0.38 / (rrf_k + rank)
            if "dense" not in target["retrieval"]:
                target["retrieval"].append("dense")

        ranked = sorted(fused.values(), key=lambda item: item["score"], reverse=True)[:k]
        return [
            MemoryHit(
                memory_id=item["memory_id"],
                kind=item.get("kind") or "fact",
                title=item.get("title"),
                content=item["content"],
                source=item.get("source") or "user",
                score=float(item["score"]),
                retrieval=list(item.get("retrieval") or []),
            )
            for item in ranked
        ]

    async def _embed_record(self, record: dict) -> None:
        if self.embedder is None or not self.embedding_model or not record:
            return
        try:
            vectors = await self.embedder.embed([_embedding_text(record)])
            if vectors and vectors[0]:
                self.store.save_embedding(record["id"], self.embedding_model, vectors[0])
        except Exception:
            # Durable memory stays searchable through FTS5 even when the local embedder is offline.
            return


def _embedding_text(record: dict) -> str:
    title = record.get("title") or ""
    return f"{record.get('kind', 'fact')}\n{title}\n{record.get('content', '')}".strip()


def _cosine(left: list[float], right: list[float]) -> float:
    if not left or not right or len(left) != len(right):
        return -1.0
    dot = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(a * a for a in left))
    right_norm = math.sqrt(sum(b * b for b in right))
    denominator = left_norm * right_norm
    return dot / denominator if denominator else -1.0
