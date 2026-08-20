from __future__ import annotations

from typing import Protocol
import httpx
from pydantic import BaseModel


class ModelMessage(BaseModel):
    role: str
    content: str


class ModelResult(BaseModel):
    content: str
    provider: str
    model: str
    fallback: bool = False
    error: str | None = None


class ModelProvider(Protocol):
    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult: ...


class OllamaProvider:
    def __init__(self, *, url: str, model: str, timeout_seconds: float = 45):
        self.url = url
        self.model = model
        self.timeout_seconds = timeout_seconds

    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        payload_messages = [{"role": "system", "content": system_prompt}] + [m.model_dump() for m in messages]
        payload = {
            "model": self.model,
            "messages": payload_messages,
            "stream": False,
            "options": {"temperature": 0.3},
        }
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            response = await client.post(self.url, json=payload)
            response.raise_for_status()
            data = response.json()
        content = str((data.get("message") or {}).get("content") or "").strip()
        if not content:
            raise ValueError("ollama_empty_response")
        return ModelResult(content=content, provider="ollama", model=self.model)


class FallbackProvider:
    def __init__(self, reason: str = "primary_unavailable"):
        self.reason = reason

    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        last = next((m.content for m in reversed(messages) if m.role == "user"), "")
        return ModelResult(
            content=f"Local model is unavailable. Lumi stored your message: {last}",
            provider="fallback",
            model="deterministic",
            fallback=True,
            error=self.reason,
        )


class ModelGateway:
    def __init__(self, primary: ModelProvider, fallback: ModelProvider | None = None):
        self.primary = primary
        self.fallback = fallback or FallbackProvider()

    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        try:
            return await self.primary.complete(messages, system_prompt)
        except Exception as exc:
            result = await self.fallback.complete(messages, system_prompt)
            return result.model_copy(update={"error": type(exc).__name__})
