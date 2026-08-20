from __future__ import annotations

from typing import Protocol
from pydantic import BaseModel


class RetrievedChunk(BaseModel):
    chunk_id: str
    document_id: str
    text: str
    score: float
    page: int | None = None
    section: str | None = None


class Retriever(Protocol):
    async def retrieve(self, query: str, *, k: int = 6) -> list[RetrievedChunk]: ...
