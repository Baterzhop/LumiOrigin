from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated

from fastapi import APIRouter, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from lumi_core import __version__
from lumi_core.agent.generations import GenerationRegistry
from lumi_core.agent.planner import LLMTaskPlanner
from lumi_core.agent.runtime import AgentRuntime, ChatResponse, ChatStreamEvent
from lumi_core.agent.task_runtime import TaskRuntime
from lumi_core.api.hardening import configure_hardening
from lumi_core.config import Settings
from lumi_core.developer.api import build_developer_router
from lumi_core.memory import ConversationContextManager, MemoryService, MemoryStore
from lumi_core.models.gateway import ModelGateway, OllamaProvider
from lumi_core.rag.embeddings import OllamaEmbeddingProvider
from lumi_core.rag.ingestion import IngestionService
from lumi_core.rag.rerank import CrossEncoderReranker
from lumi_core.rag.retrieval import HybridRetriever
from lumi_core.storage.database import Database
from lumi_core.storage.maintenance import DatabaseMaintenance
from lumi_core.tools import PolicyEngine, ToolRegistry, Workspace, build_default_registry


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=100_000)
    conversation_id: str | None = None


class KnowledgeQueryRequest(BaseModel):
    query: str = Field(min_length=1, max_length=20_000)
    k: int = Field(default=6, ge=1, le=20)


class TaskCreateRequest(BaseModel):
    goal: str = Field(min_length=1, max_length=50_000)
    conversation_id: str | None = None
    max_steps: int = Field(default=8, ge=1, le=20)
    max_tool_calls: int = Field(default=6, ge=0, le=20)
    max_seconds: int = Field(default=120, ge=5, le=600)


class MemoryCreateRequest(BaseModel):
    content: str = Field(min_length=1, max_length=50_000)
    kind: str = Field(default="fact", min_length=1, max_length=64)
    title: str | None = Field(default=None, max_length=200)
    approved_by_user: bool = False


class MemoryUpdateRequest(BaseModel):
    content: str | None = Field(default=None, min_length=1, max_length=50_000)
    kind: str | None = Field(default=None, min_length=1, max_length=64)
    title: str | None = Field(default=None, max_length=200)


class MemoryQueryRequest(BaseModel):
    query: str = Field(min_length=1, max_length=20_000)
    k: int = Field(default=4, ge=1, le=20)


@dataclass(slots=True)
class AppServices:
    settings: Settings
    database: Database
    database_maintenance: DatabaseMaintenance
    model_gateway: ModelGateway
    embedding_provider: OllamaEmbeddingProvider | None
    ingestion: IngestionService
    retriever: HybridRetriever
    memory_store: MemoryStore
    memory_service: MemoryService
    runtime: AgentRuntime
    generations: GenerationRegistry
    workspace: Workspace
    tool_registry: ToolRegistry
    task_runtime: TaskRuntime


def build_services(settings: Settings) -> AppServices:
    """Construct one isolated Lumi Core service graph for one FastAPI app instance."""

    database = Database(settings.database_path)
    database_maintenance = DatabaseMaintenance(database)
    if settings.backup_before_migrate and database.path.exists() and database.path.stat().st_size > 0:
        database_maintenance.create_backup(settings.backup_dir, prefix="pre-migrate")
        database_maintenance.prune_backups(settings.backup_dir, keep=settings.backup_keep, prefix="pre-migrate")
    database.migrate()
    integrity_ok, integrity_detail = database_maintenance.integrity_check()
    if not integrity_ok:
        raise RuntimeError(f"database_integrity_check_failed:{integrity_detail}")

    model_gateway = ModelGateway(
        OllamaProvider(
            url=settings.ollama_url,
            model=settings.ollama_model,
            timeout_seconds=settings.model_timeout_seconds,
        )
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
    ingestion = IngestionService(
        database,
        embedder=embedding_provider,
        embedding_model=settings.embedding_model if embedding_provider else None,
    )
    retriever = HybridRetriever(
        database,
        embedder=embedding_provider,
        embedding_model=settings.embedding_model if embedding_provider else None,
        reranker=reranker,
    )
    memory_store = MemoryStore(database)
    memory_service = MemoryService(
        memory_store,
        embedder=embedding_provider,
        embedding_model=settings.embedding_model if embedding_provider else None,
    )
    context_manager = ConversationContextManager(
        database,
        memory_store,
        model_gateway,
        max_input_tokens=settings.context_max_input_tokens,
        recent_token_budget=settings.context_recent_tokens,
        summary_target_tokens=settings.context_summary_tokens,
    )
    runtime = AgentRuntime(
        database,
        model_gateway,
        retriever=retriever,
        context_manager=context_manager,
        memory_service=memory_service,
        memory_k=settings.memory_recall_k,
    )
    generations = GenerationRegistry()
    workspace = Workspace(settings.tool_workspace_root, max_read_bytes=settings.tool_max_read_bytes)
    tool_registry = build_default_registry(workspace, retriever)
    policy_engine = PolicyEngine()
    task_runtime = TaskRuntime(database, tool_registry, policy_engine, LLMTaskPlanner(model_gateway))

    return AppServices(
        settings=settings,
        database=database,
        database_maintenance=database_maintenance,
        model_gateway=model_gateway,
        embedding_provider=embedding_provider,
        ingestion=ingestion,
        retriever=retriever,
        memory_store=memory_store,
        memory_service=memory_service,
        runtime=runtime,
        generations=generations,
        workspace=workspace,
        tool_registry=tool_registry,
        task_runtime=task_runtime,
    )


def _services(request: Request) -> AppServices:
    services = getattr(request.app.state, "lumi", None)
    if not isinstance(services, AppServices):
        raise RuntimeError("lumi_services_not_initialized")
    return services


def _sse(event: ChatStreamEvent) -> str:
    return f"event: {event.type}\ndata: {event.model_dump_json(exclude_none=True)}\n\n"


router = APIRouter()


@router.get("/health")
def health() -> dict:
    return {"ok": True, "service": "lumi-core", "version": __version__}


@router.get("/ready")
def ready(request: Request) -> dict:
    services = _services(request)
    ok, detail = services.database_maintenance.integrity_check()
    if not ok:
        raise HTTPException(status_code=503, detail=f"database_not_ready:{detail}")
    return {"ok": True, "database": "ok", "version": __version__}


@router.get("/v1/runtime")
async def runtime_status(request: Request) -> dict:
    services = _services(request)
    settings = services.settings
    return {
        "ok": True,
        "streaming": True,
        "provider": "ollama",
        "model": settings.ollama_model,
        "active_generations": await services.generations.active_count(),
        "security": {
            "api_key_required": bool(settings.api_key),
            "local_only_without_api_key": True,
            "api_docs_enabled": settings.api_docs_enabled,
            "trusted_hosts": list(settings.trusted_hosts),
            "cors_enabled": bool(settings.cors_origins),
        },
        "storage": {
            "database": str(services.database.path),
            "backup_dir": str(settings.backup_dir),
            "backup_before_migrate": settings.backup_before_migrate,
            "backup_keep": settings.backup_keep,
        },
        "rag": {
            "sparse": "sqlite-fts5",
            "dense_enabled": settings.rag_dense_enabled,
            "embedding_model": settings.embedding_model if settings.rag_dense_enabled else None,
            "reranker_model": settings.reranker_model,
        },
        "memory": {
            "count": len(services.memory_service.list(limit=500)),
            "semantic_enabled": services.embedding_provider is not None,
            "embedding_model": settings.embedding_model if services.embedding_provider else None,
            "recall_k": settings.memory_recall_k,
            "context_max_input_tokens": settings.context_max_input_tokens,
            "context_recent_tokens": settings.context_recent_tokens,
        },
        "tools": {
            "count": len(services.tool_registry.specs()),
            "workspace": str(services.workspace.root),
            "critical_enabled": False,
        },
    }


@router.post("/v1/admin/backup")
def create_database_backup(request: Request) -> dict:
    services = _services(request)
    settings = services.settings
    try:
        path = services.database_maintenance.create_backup(settings.backup_dir)
        removed = services.database_maintenance.prune_backups(
            settings.backup_dir,
            keep=settings.backup_keep,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"backup_failed:{type(exc).__name__}") from exc
    return {"ok": True, "backup": str(path), "pruned": len(removed)}


@router.post("/v1/chat", response_model=ChatResponse)
async def chat(request_body: ChatRequest, request: Request) -> ChatResponse:
    try:
        return await _services(request).runtime.chat(request_body.message, request_body.conversation_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/v1/chat/stream")
async def chat_stream(request_body: ChatRequest, request: Request) -> StreamingResponse:
    services = _services(request)
    handle = await services.generations.create()

    async def event_source():
        try:
            async for event in services.runtime.stream_chat(
                request_body.message,
                generation_id=handle.generation_id,
                cancel_event=handle.cancel_event,
                conversation_id=request_body.conversation_id,
            ):
                yield _sse(event)
        finally:
            await services.generations.release(handle.generation_id)

    return StreamingResponse(
        event_source(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "X-Accel-Buffering": "no"},
    )


@router.post("/v1/generations/{generation_id}/cancel")
async def cancel_generation(generation_id: str, request: Request) -> dict:
    if not await _services(request).generations.cancel(generation_id):
        raise HTTPException(status_code=404, detail="generation_not_found")
    return {"ok": True, "generation_id": generation_id, "cancel_requested": True}


@router.get("/v1/conversations/{conversation_id}/messages")
def messages(conversation_id: str, request: Request, limit: int = 30) -> dict:
    database = _services(request).database
    if not database.conversation_exists(conversation_id):
        raise HTTPException(status_code=404, detail="conversation_not_found")
    return {"conversation_id": conversation_id, "messages": database.list_messages(conversation_id, limit)}


@router.get("/v1/conversations/{conversation_id}/summary")
def conversation_summary(conversation_id: str, request: Request) -> dict:
    services = _services(request)
    if not services.database.conversation_exists(conversation_id):
        raise HTTPException(status_code=404, detail="conversation_not_found")
    return {
        "conversation_id": conversation_id,
        "summary": services.memory_store.get_summary(conversation_id),
    }


@router.post("/v1/knowledge/upload")
async def upload_knowledge(
    request: Request,
    file: Annotated[UploadFile, File()],
    title: Annotated[str | None, Form()] = None,
    source: Annotated[str | None, Form()] = None,
) -> dict:
    services = _services(request)
    data = await file.read(services.settings.max_upload_bytes + 1)
    if len(data) > services.settings.max_upload_bytes:
        raise HTTPException(status_code=413, detail="document_too_large")
    try:
        result = await services.ingestion.ingest_bytes(
            filename=file.filename or "upload.txt",
            data=data,
            source=source,
            title=title,
            content_type=file.content_type,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return result.model_dump()


@router.post("/v1/knowledge/query")
async def query_knowledge(request_body: KnowledgeQueryRequest, request: Request) -> dict:
    hits = await _services(request).retriever.retrieve(request_body.query, k=request_body.k)
    return {"query": request_body.query, "hits": [hit.model_dump() for hit in hits]}


@router.get("/v1/knowledge/documents")
def knowledge_documents(request: Request, limit: int = 100) -> dict:
    return {"documents": _services(request).database.list_documents(limit)}


@router.get("/v1/memories")
def list_memories(request: Request, limit: int = 100) -> dict:
    return {"memories": _services(request).memory_service.list(limit=limit)}


@router.post("/v1/memories")
async def create_memory(request_body: MemoryCreateRequest, request: Request) -> dict:
    if not request_body.approved_by_user:
        raise HTTPException(status_code=400, detail="explicit_user_approval_required")
    try:
        memory = await _services(request).memory_service.create(
            request_body.content,
            kind=request_body.kind,
            title=request_body.title,
            source="user",
            metadata={"approval": "explicit_api_user_action"},
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"memory": memory}


@router.patch("/v1/memories/{memory_id}")
async def update_memory(memory_id: str, request_body: MemoryUpdateRequest, request: Request) -> dict:
    try:
        memory = await _services(request).memory_service.update(
            memory_id,
            content=request_body.content,
            kind=request_body.kind,
            title=request_body.title,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if memory is None:
        raise HTTPException(status_code=404, detail="memory_not_found")
    return {"memory": memory}


@router.delete("/v1/memories/{memory_id}")
def delete_memory(memory_id: str, request: Request) -> dict:
    if not _services(request).memory_service.delete(memory_id):
        raise HTTPException(status_code=404, detail="memory_not_found")
    return {"ok": True, "memory_id": memory_id, "deleted": True}


@router.post("/v1/memories/search")
async def search_memories(request_body: MemoryQueryRequest, request: Request) -> dict:
    hits = await _services(request).memory_service.search(request_body.query, k=request_body.k)
    return {"query": request_body.query, "hits": [hit.model_dump() for hit in hits]}


@router.get("/v1/tools")
def tools(request: Request) -> dict:
    return {"tools": [spec.model_dump() for spec in _services(request).tool_registry.specs()]}


@router.post("/v1/tasks")
async def create_task(request_body: TaskCreateRequest, request: Request) -> dict:
    try:
        return await _services(request).task_runtime.create_and_run(
            request_body.goal,
            conversation_id=request_body.conversation_id,
            max_steps=request_body.max_steps,
            max_tool_calls=request_body.max_tool_calls,
            max_seconds=request_body.max_seconds,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.get("/v1/tasks/{task_id}")
def get_task(task_id: str, request: Request) -> dict:
    try:
        return _services(request).task_runtime.snapshot(task_id)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.post("/v1/tool-calls/{tool_call_id}/approve")
async def approve_tool_call(tool_call_id: str, request: Request) -> dict:
    try:
        return await _services(request).task_runtime.approve(tool_call_id)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.post("/v1/tool-calls/{tool_call_id}/deny")
async def deny_tool_call(tool_call_id: str, request: Request) -> dict:
    try:
        return await _services(request).task_runtime.deny(tool_call_id)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create an isolated Lumi Core application without module-import side effects."""

    resolved = settings or Settings.from_env()
    services = build_services(resolved)
    app = FastAPI(
        title="Lumi Core",
        version=__version__,
        docs_url="/docs" if resolved.api_docs_enabled else None,
        redoc_url=None,
        openapi_url="/openapi.json" if resolved.api_docs_enabled else None,
    )
    app.state.lumi = services
    configure_hardening(app, resolved)
    app.include_router(build_developer_router(resolved, services.database, services.model_gateway))
    app.include_router(router)
    return app
