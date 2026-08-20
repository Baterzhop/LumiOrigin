from __future__ import annotations

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from lumi_core import __version__
from lumi_core.agent.runtime import AgentRuntime, ChatResponse
from lumi_core.config import Settings
from lumi_core.models.gateway import ModelGateway, OllamaProvider
from lumi_core.storage.database import Database


class ChatRequest(BaseModel):
    message: str
    conversation_id: str | None = None


settings = Settings.from_env()
database = Database(settings.database_path)
database.migrate()
model_gateway = ModelGateway(
    OllamaProvider(
        url=settings.ollama_url,
        model=settings.ollama_model,
        timeout_seconds=settings.model_timeout_seconds,
    )
)
runtime = AgentRuntime(database, model_gateway)

app = FastAPI(title="Lumi Core", version=__version__)


@app.get("/health")
def health() -> dict:
    return {"ok": True, "service": "lumi-core", "version": __version__}


@app.post("/v1/chat", response_model=ChatResponse)
async def chat(request: ChatRequest) -> ChatResponse:
    try:
        return await runtime.chat(request.message, request.conversation_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/v1/conversations/{conversation_id}/messages")
def messages(conversation_id: str, limit: int = 30) -> dict:
    if not database.conversation_exists(conversation_id):
        raise HTTPException(status_code=404, detail="conversation_not_found")
    return {"conversation_id": conversation_id, "messages": database.list_messages(conversation_id, limit)}
