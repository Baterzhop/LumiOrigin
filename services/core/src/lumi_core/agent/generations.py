from __future__ import annotations

import asyncio
from dataclasses import dataclass
import uuid


@dataclass(slots=True)
class GenerationHandle:
    generation_id: str
    cancel_event: asyncio.Event


class GenerationRegistry:
    def __init__(self):
        self._items: dict[str, asyncio.Event] = {}
        self._lock = asyncio.Lock()

    async def create(self) -> GenerationHandle:
        generation_id = str(uuid.uuid4())
        event = asyncio.Event()
        async with self._lock:
            self._items[generation_id] = event
        return GenerationHandle(generation_id=generation_id, cancel_event=event)

    async def cancel(self, generation_id: str) -> bool:
        async with self._lock:
            event = self._items.get(generation_id)
            if event is None:
                return False
            event.set()
            return True

    async def release(self, generation_id: str) -> None:
        async with self._lock:
            self._items.pop(generation_id, None)

    async def active_count(self) -> int:
        async with self._lock:
            return len(self._items)
