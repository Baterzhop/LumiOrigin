from __future__ import annotations

from typing import Protocol
from pydantic import BaseModel, Field


class RetrievedChunk(BaseModel):
    chunk_id: str
    document_id: str
    title: str | None = None
    source: str | None = None
    text: str
    score: float
    page: int | None = None
    section: str | None = None
    retrieval: list[str] = Field(default_factory=list)


class Retriever(Protocol):
    async def retrieve(self, query: str, *, k: int = 6) -> list[RetrievedChunk]: ...
