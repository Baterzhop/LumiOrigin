from __future__ import annotations

import asyncio
from typing import Protocol

from lumi_core.rag.contracts import RetrievedChunk


class Reranker(Protocol):
    async def rerank(self, query: str, chunks: list[RetrievedChunk]) -> list[RetrievedChunk]: ...


class CrossEncoderReranker:
    """Lazy/cached sentence-transformers CrossEncoder. Install lumi-core[rerank] to enable."""

    def __init__(self, model_name: str):
        self.model_name = model_name
        self._model = None
        self._lock = asyncio.Lock()

    async def _load(self):
        if self._model is not None:
            return self._model
        async with self._lock:
            if self._model is None:
                from sentence_transformers import CrossEncoder

                self._model = await asyncio.to_thread(CrossEncoder, self.model_name)
        return self._model

    async def rerank(self, query: str, chunks: list[RetrievedChunk]) -> list[RetrievedChunk]:
        if len(chunks) < 2:
            return chunks
        model = await self._load()
        pairs = [(query, chunk.text) for chunk in chunks]
        scores = await asyncio.to_thread(model.predict, pairs)
        reranked = [
            chunk.model_copy(update={"score": float(score), "retrieval": [*chunk.retrieval, "rerank"]})
            for chunk, score in zip(chunks, scores, strict=True)
        ]
        return sorted(reranked, key=lambda item: item.score, reverse=True)
