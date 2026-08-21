from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from io import BytesIO
from pathlib import Path
import re

from pydantic import BaseModel
from pypdf import PdfReader

from lumi_core.rag.embeddings import EmbeddingProvider
from lumi_core.storage.database import Database


@dataclass(slots=True)
class ParsedSection:
    text: str
    page: int | None = None
    section: str | None = None


class IngestionResult(BaseModel):
    document_id: str
    title: str
    source: str
    mime_type: str
    chunk_count: int
    deduplicated: bool
    embedding_model: str | None = None
    embedded_chunks: int = 0
    embedding_error: str | None = None


class IngestionService:
    def __init__(
        self,
        database: Database,
        *,
        embedder: EmbeddingProvider | None = None,
        embedding_model: str | None = None,
        chunk_words: int = 220,
        overlap_words: int = 40,
        embedding_batch_size: int = 32,
    ):
        self.database = database
        self.embedder = embedder
        self.embedding_model = embedding_model
        self.chunk_words = max(80, chunk_words)
        self.overlap_words = max(0, min(overlap_words, self.chunk_words // 2))
        self.embedding_batch_size = max(1, embedding_batch_size)

    async def ingest_bytes(
        self,
        *,
        filename: str,
        data: bytes,
        source: str | None = None,
        title: str | None = None,
        content_type: str | None = None,
    ) -> IngestionResult:
        if not data:
            raise ValueError("empty_document")
        title = (title or Path(filename).name or "Untitled").strip()
        source = (source or f"upload:{Path(filename).name}").strip()
        mime_type = self._mime_type(filename, content_type)
        content_hash = sha256(data).hexdigest()
        existing = self.database.find_document_by_hash(content_hash)

        if existing:
            document_id = existing["id"]
            chunks = self.database.get_chunks_for_document(document_id)
            embedded, embedding_error = await self._ensure_embeddings(chunks)
            return IngestionResult(
                document_id=document_id,
                title=existing.get("title") or title,
                source=existing.get("source") or source,
                mime_type=existing.get("mime_type") or mime_type,
                chunk_count=len(chunks),
                deduplicated=True,
                embedding_model=self.embedding_model if self.embedder else None,
                embedded_chunks=embedded,
                embedding_error=embedding_error,
            )

        sections = self._parse(data, filename, mime_type)
        chunks = self._chunk(sections)
        if not chunks:
            raise ValueError("document_has_no_extractable_text")

        document_id = f"doc_{content_hash[:24]}"
        self.database.create_document(
            document_id=document_id,
            source=source,
            title=title,
            content_hash=content_hash,
            language=None,
            mime_type=mime_type,
            metadata={"filename": Path(filename).name, "parser": "lumi-v4-m2"},
        )
        for ordinal, chunk in enumerate(chunks):
            chunk["ordinal"] = ordinal
            identity = f"{document_id}:{ordinal}:{chunk['content_hash']}"
            chunk["id"] = f"chk_{sha256(identity.encode()).hexdigest()[:24]}"
        self.database.replace_document_chunks(document_id, chunks)
        stored = self.database.get_chunks_for_document(document_id)
        embedded, embedding_error = await self._ensure_embeddings(stored)
        return IngestionResult(
            document_id=document_id,
            title=title,
            source=source,
            mime_type=mime_type,
            chunk_count=len(stored),
            deduplicated=False,
            embedding_model=self.embedding_model if self.embedder else None,
            embedded_chunks=embedded,
            embedding_error=embedding_error,
        )

    def _mime_type(self, filename: str, content_type: str | None) -> str:
        suffix = Path(filename).suffix.lower()
        if suffix == ".pdf" or content_type == "application/pdf":
            return "application/pdf"
        if suffix in {".md", ".markdown"}:
            return "text/markdown"
        if suffix in {".txt", ".text", ""}:
            return "text/plain"
        if content_type and content_type.startswith("text/"):
            return content_type
        raise ValueError("unsupported_document_type")

    def _parse(self, data: bytes, filename: str, mime_type: str) -> list[ParsedSection]:
        if mime_type == "application/pdf":
            reader = PdfReader(BytesIO(data), strict=False)
            sections: list[ParsedSection] = []
            for index, page in enumerate(reader.pages, start=1):
                text = (page.extract_text() or "").strip()
                if text:
                    sections.append(ParsedSection(text=text, page=index, section=f"page-{index}"))
            return sections
        text = data.decode("utf-8", errors="replace").strip()
        return [ParsedSection(text=text, section=Path(filename).suffix.lower().lstrip(".") or "text")] if text else []

    def _chunk(self, sections: list[ParsedSection]) -> list[dict]:
        chunks: list[dict] = []
        for section in sections:
            words = re.findall(r"\S+", section.text)
            start = 0
            while start < len(words):
                end = min(len(words), start + self.chunk_words)
                text = " ".join(words[start:end]).strip()
                if text:
                    chunks.append(
                        {
                            "text": text,
                            "page": section.page,
                            "section": section.section,
                            "content_hash": sha256(text.encode("utf-8")).hexdigest(),
                            "token_count": len(words[start:end]),
                            "metadata": {},
                        }
                    )
                if end >= len(words):
                    break
                start = end - self.overlap_words
        return chunks

    async def _ensure_embeddings(self, chunks: list[dict]) -> tuple[int, str | None]:
        if self.embedder is None or not self.embedding_model or not chunks:
            return 0, None
        document_id = chunks[0]["document_id"]
        if self.database.embedding_count(document_id, self.embedding_model) >= len(chunks):
            return len(chunks), None
        try:
            saved = 0
            for start in range(0, len(chunks), self.embedding_batch_size):
                batch = chunks[start : start + self.embedding_batch_size]
                vectors = await self.embedder.embed([chunk["text"] for chunk in batch])
                if len(vectors) != len(batch):
                    raise ValueError("embedding_count_mismatch")
                self.database.save_embeddings(
                    self.embedding_model,
                    [(chunk["id"], vector) for chunk, vector in zip(batch, vectors, strict=True)],
                )
                saved += len(batch)
            return saved, None
        except Exception as exc:
            return 0, type(exc).__name__
