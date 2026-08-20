from __future__ import annotations

from typing import Protocol
import hashlib
import math

import httpx


class EmbeddingProvider(Protocol):
    async def embed(self, texts: list[str]) -> list[list[float]]: ...


class OllamaEmbeddingProvider:
    def __init__(self, *, url: str, model: str, timeout_seconds: float = 60):
        self.url = url
        self.model = model
        self.timeout_seconds = timeout_seconds

    async def embed(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            response = await client.post(self.url, json={"model": self.model, "input": texts})
            response.raise_for_status()
            data = response.json()
        vectors = data.get("embeddings")
        if not isinstance(vectors, list) or len(vectors) != len(texts):
            raise ValueError("invalid_embedding_response")
        result = [[float(value) for value in vector] for vector in vectors]
        if any(not vector for vector in result):
            raise ValueError("empty_embedding")
        return result


class HashEmbeddingProvider:
    """Deterministic lightweight embedder for tests; not a semantic production model."""

    def __init__(self, dimensions: int = 64):
        self.dimensions = max(8, dimensions)

    async def embed(self, texts: list[str]) -> list[list[float]]:
        return [self._one(text) for text in texts]

    def _one(self, text: str) -> list[float]:
        vector = [0.0] * self.dimensions
        for token in text.lower().split():
            digest = hashlib.sha256(token.encode("utf-8")).digest()
            index = int.from_bytes(digest[:4], "big") % self.dimensions
            sign = -1.0 if digest[4] & 1 else 1.0
            vector[index] += sign
        norm = math.sqrt(sum(value * value for value in vector)) or 1.0
        return [value / norm for value in vector]
