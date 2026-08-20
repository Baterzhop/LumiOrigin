from __future__ import annotations

from typing import Annotated

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from lumi_core import __version__
from lumi_core.agent.generations import GenerationRegistry
from lumi_core.agent.runtime import AgentRuntime, ChatResponse, ChatStreamEvent
from lumi_core.config import Settings
from lumi_core.models.gateway import ModelGateway, OllamaProvider
from lumi_core.rag.embeddings import OllamaEmbeddingProvider
from lumi_core.rag.ingestion import IngestionService
from lumi_core.rag.rerank import CrossEncoderReranker
from lumi_core.rag.retrieval import HybridRetriever
from lumi_core.storage.database import Database


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=100_000)
    conversation_id: str | None = None


class KnowledgeQueryRequest(BaseModel):
    query: str = Field(min_length=1, max_length=20_000)
    k: int = Field(default=6, ge=1, le=20)


settings = Settings.from_env()
database = Database(settings.database_path)
database.migrate()
model_gateway = ModelGateway(
    OllamaProvider(url=settings.ollama_url, model=settings.ollama_model, timeout_seconds=settings.model_timeout_seconds)
)
embedding_provider = (
    OllamaEmbeddingProvider(
        url=settings.ollama_embed_url,
        model=settings.embedding_model,
        timeout_seconds=settings.model_timeout_seconds,
    )
    if settings.rag_dense_enabled
    else None
)
reranker = CrossEncoderReranker(settings.reranker_model) if settings.reranker_model else None
ingestion = IngestionService(database, embedder=embedding_provider, embedding_model=settings.embedding_model if embedding_provider else None)
retriever = HybridRetriever(
    database,
    embedder=embedding_provider,
    embedding_model=settings.embedding_model if embedding_provider else None,
    reranker=reranker,
)
runtime = AgentRuntime(database, model_gateway, retriever=retriever)
generations = GenerationRegistry()

app = FastAPI(title="Lumi Core", version=__version__)


def _sse(event: ChatStreamEvent) -> str:
    return f"event: {event.type}\ndata: {event.model_dump_json(exclude_none=True)}\n\n"


@app.get("/health")
def health() -> dict:
    return {"ok": True, "service": "lumi-core", "version": __version__}


@app.get("/v1/runtime")
async def runtime_status() -> dict:
    return {
        "ok": True,
        "streaming": True,
        "provider": "ollama",
        "model": settings.ollama_model,
        "active_generations": await generations.active_count(),
        "rag": {
            "sparse": "sqlite-fts5",
            "dense_enabled": settings.rag_dense_enabled,
            "embedding_model": settings.embedding_model if settings.rag_dense_enabled else None,
            "reranker_model": settings.reranker_model,
        },
    }


@app.post("/v1/chat", response_model=ChatResponse)
async def chat(request: ChatRequest) -> ChatResponse:
    try:
        return await runtime.chat(request.message, request.conversation_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/v1/chat/stream")
async def chat_stream(request: ChatRequest) -> StreamingResponse:
    handle = await generations.create()

    async def event_source():
        try:
            async for event in runtime.stream_chat(
                request.message,
                generation_id=handle.generation_id,
                cancel_event=handle.cancel_event,
                conversation_id=request.conversation_id,
            ):
                yield _sse(event)
        finally:
            await generations.release(handle.generation_id)

    return StreamingResponse(
        event_source(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "X-Accel-Buffering": "no"},
    )


@app.post("/v1/generations/{generation_id}/cancel")
async def cancel_generation(generation_id: str) -> dict:
    if not await generations.cancel(generation_id):
        raise HTTPException(status_code=404, detail="generation_not_found")
    return {"ok": True, "generation_id": generation_id, "cancel_requested": True}


@app.get("/v1/conversations/{conversation_id}/messages")
def messages(conversation_id: str, limit: int = 30) -> dict:
    if not database.conversation_exists(conversation_id):
        raise HTTPException(status_code=404, detail="conversation_not_found")
    return {"conversation_id": conversation_id, "messages": database.list_messages(conversation_id, limit)}


@app.post("/v1/knowledge/upload")
async def upload_knowledge(
    file: Annotated[UploadFile, File()],
    title: Annotated[str | None, Form()] = None,
    source: Annotated[str | None, Form()] = None,
) -> dict:
    data = await file.read(settings.max_upload_bytes + 1)
    if len(data) > settings.max_upload_bytes:
        raise HTTPException(status_code=413, detail="document_too_large")
    try:
        result = await ingestion.ingest_bytes(
            filename=file.filename or "upload.txt",
            data=data,
            source=source,
            title=title,
            content_type=file.content_type,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return result.model_dump()


@app.post("/v1/knowledge/query")
async def query_knowledge(request: KnowledgeQueryRequest) -> dict:
    hits = await retriever.retrieve(request.query, k=request.k)
    return {"query": request.query, "hits": [hit.model_dump() for hit in hits]}


@app.get("/v1/knowledge/documents")
def knowledge_documents(limit: int = 100) -> dict:
    return {"documents": database.list_documents(limit)}
