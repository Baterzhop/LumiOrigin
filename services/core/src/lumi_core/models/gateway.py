from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterator
from typing import Literal, Protocol

import httpx
from pydantic import BaseModel


class GenerationCancelled(Exception):
    pass


class ModelMessage(BaseModel):
    role: str
    content: str


class ModelResult(BaseModel):
    content: str
    provider: str
    model: str
    fallback: bool = False
    error: str | None = None


class ModelStreamEvent(BaseModel):
    type: Literal["delta", "completed"]
    delta: str | None = None
    provider: str
    model: str
    fallback: bool = False
    error: str | None = None


class ModelProvider(Protocol):
    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult: ...


class OllamaProvider:
    provider_name = "ollama"

    def __init__(self, *, url: str, model: str, timeout_seconds: float = 45):
        self.url = url
        self.model = model
        self.model_name = model
        self.timeout_seconds = timeout_seconds

    def _payload(self, messages: list[ModelMessage], system_prompt: str, *, stream: bool) -> dict:
        payload_messages = [{"role": "system", "content": system_prompt}] + [m.model_dump() for m in messages]
        return {
            "model": self.model,
            "messages": payload_messages,
            "stream": stream,
            "options": {"temperature": 0.3},
        }

    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            response = await client.post(self.url, json=self._payload(messages, system_prompt, stream=False))
            response.raise_for_status()
            data = response.json()
        content = str((data.get("message") or {}).get("content") or "").strip()
        if not content:
            raise ValueError("ollama_empty_response")
        return ModelResult(content=content, provider=self.provider_name, model=self.model)

    async def stream(
        self,
        messages: list[ModelMessage],
        system_prompt: str,
        *,
        cancel_event: asyncio.Event | None = None,
    ) -> AsyncIterator[ModelStreamEvent]:
        emitted = False
        async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
            async with client.stream("POST", self.url, json=self._payload(messages, system_prompt, stream=True)) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if cancel_event is not None and cancel_event.is_set():
                        raise GenerationCancelled()
                    if not line.strip():
                        continue
                    data = json.loads(line)
                    delta = str((data.get("message") or {}).get("content") or "")
                    if delta:
                        emitted = True
                        yield ModelStreamEvent(
                            type="delta",
                            delta=delta,
                            provider=self.provider_name,
                            model=self.model,
                        )
                    if data.get("done") is True:
                        if not emitted:
                            raise ValueError("ollama_empty_response")
                        yield ModelStreamEvent(type="completed", provider=self.provider_name, model=self.model)
                        return
        if emitted:
            yield ModelStreamEvent(type="completed", provider=self.provider_name, model=self.model)
        else:
            raise ValueError("ollama_empty_response")


class FallbackProvider:
    provider_name = "fallback"
    model_name = "deterministic"

    def __init__(self, reason: str = "primary_unavailable"):
        self.reason = reason

    async def complete(self, messages: list[ModelMessage], system_prompt: str) -> ModelResult:
        last = next((m.content for m in reversed(messages) if m.role == "user"), "")
        return ModelResult(
            content=f"Local model is unavailable. Lumi stored your message: {last}",
            provider=self.provider_name,
            model=self.model_name,
            fallback=True,
            error=self.reason,
        )

    async def stream(
        self,
        messages: list[ModelMessage],
        system_prompt: str,
        *,
        cancel_event: asyncio.Event | None = None,
    ) -> AsyncIterator[ModelStreamEvent]:
        if cancel_event is not None and cancel_event.is_set():
            raise GenerationCancelled()
        result = await self.complete(messages, system_prompt)
        yield ModelStreamEvent(
            type="delta",
            delta=result.content,
            provider=result.provider,
            model=result.model,
            fallback=True,
            error=result.error,
        )
        yield ModelStreamEvent(
            type="completed",
            provider=result.provider,
            model=result.model,
            fallback=True,
            error=result.error,
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

    async def stream(
        self,
        messages: list[ModelMessage],
        system_prompt: str,
        *,
        cancel_event: asyncio.Event | None = None,
    ) -> AsyncIterator[ModelStreamEvent]:
        emitted = False
        primary_stream = getattr(self.primary, "stream", None)
        if primary_stream is None:
            try:
                result = await self.primary.complete(messages, system_prompt)
                if cancel_event is not None and cancel_event.is_set():
                    raise GenerationCancelled()
                yield ModelStreamEvent(
                    type="delta",
                    delta=result.content,
                    provider=result.provider,
                    model=result.model,
                    fallback=result.fallback,
                    error=result.error,
                )
                yield ModelStreamEvent(
                    type="completed",
                    provider=result.provider,
                    model=result.model,
                    fallback=result.fallback,
                    error=result.error,
                )
                return
            except GenerationCancelled:
                raise
            except Exception as exc:
                async for event in self._fallback_stream(messages, system_prompt, cancel_event, type(exc).__name__):
                    yield event
                return

        try:
            async for event in primary_stream(messages, system_prompt, cancel_event=cancel_event):
                if cancel_event is not None and cancel_event.is_set():
                    raise GenerationCancelled()
                if event.type == "delta" and event.delta:
                    emitted = True
                yield event
        except GenerationCancelled:
            raise
        except Exception as exc:
            if emitted:
                yield ModelStreamEvent(
                    type="completed",
                    provider=getattr(self.primary, "provider_name", "primary"),
                    model=getattr(self.primary, "model_name", "unknown"),
                    error=type(exc).__name__,
                )
                return
            async for event in self._fallback_stream(messages, system_prompt, cancel_event, type(exc).__name__):
                yield event

    async def _fallback_stream(
        self,
        messages: list[ModelMessage],
        system_prompt: str,
        cancel_event: asyncio.Event | None,
        error: str,
    ) -> AsyncIterator[ModelStreamEvent]:
        fallback_stream = getattr(self.fallback, "stream", None)
        if fallback_stream is None:
            result = await self.fallback.complete(messages, system_prompt)
            yield ModelStreamEvent(
                type="delta",
                delta=result.content,
                provider=result.provider,
                model=result.model,
                fallback=True,
                error=error,
            )
            yield ModelStreamEvent(
                type="completed",
                provider=result.provider,
                model=result.model,
                fallback=True,
                error=error,
            )
            return
        async for event in fallback_stream(messages, system_prompt, cancel_event=cancel_event):
            yield event.model_copy(update={"fallback": True, "error": error})
