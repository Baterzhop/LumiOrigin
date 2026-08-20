from __future__ import annotations

import json
import re
import uuid

from lumi_core.storage.database import Database


class MemoryStore:
    def __init__(self, database: Database):
        self.database = database

    def create(
        self,
        *,
        content: str,
        kind: str,
        title: str | None = None,
        source: str = "user",
        metadata: dict | None = None,
        approved: bool = True,
    ) -> dict:
        memory_id = str(uuid.uuid4())
        with self.database.connect() as connection:
            connection.execute(
                """
                INSERT INTO memories(id, kind, content, approved, title, source, metadata_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                """,
                (
                    memory_id,
                    kind,
                    content,
                    1 if approved else 0,
                    title,
                    source,
                    json.dumps(metadata or {}, ensure_ascii=False),
                ),
            )
            if approved:
                connection.execute(
                    "INSERT INTO memory_fts(memory_id, title, content) VALUES (?, ?, ?)",
                    (memory_id, title or "", content),
                )
        return self.get(memory_id) or {}

    def get(self, memory_id: str) -> dict | None:
        with self.database.connect() as connection:
            row = connection.execute(
                """
                SELECT id, kind, title, content, source, approved, metadata_json,
                       created_at, COALESCE(updated_at, created_at) AS updated_at
                FROM memories WHERE id = ?
                """,
                (memory_id,),
            ).fetchone()
        return self._decode(row) if row else None

    def list(self, limit: int = 100, *, approved_only: bool = True) -> list[dict]:
        limit = max(1, min(limit, 500))
        where = "WHERE approved = 1" if approved_only else ""
        with self.database.connect() as connection:
            rows = connection.execute(
                f"""
                SELECT id, kind, title, content, source, approved, metadata_json,
                       created_at, COALESCE(updated_at, created_at) AS updated_at
                FROM memories
                {where}
                ORDER BY COALESCE(updated_at, created_at) DESC, rowid DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [self._decode(row) for row in rows]

    def update(
        self,
        memory_id: str,
        *,
        content: str | None = None,
        title: str | None = None,
        kind: str | None = None,
        metadata: dict | None = None,
    ) -> dict | None:
        current = self.get(memory_id)
        if current is None:
            return None
        next_content = current["content"] if content is None else content
        next_title = current.get("title") if title is None else title
        next_kind = current["kind"] if kind is None else kind
        next_metadata = current.get("metadata", {}) if metadata is None else metadata
        with self.database.connect() as connection:
            connection.execute(
                """
                UPDATE memories
                SET content = ?, title = ?, kind = ?, metadata_json = ?, updated_at = CURRENT_TIMESTAMP
                WHERE id = ?
                """,
                (
                    next_content,
                    next_title,
                    next_kind,
                    json.dumps(next_metadata, ensure_ascii=False),
                    memory_id,
                ),
            )
            connection.execute("DELETE FROM memory_fts WHERE memory_id = ?", (memory_id,))
            if current["approved"]:
                connection.execute(
                    "INSERT INTO memory_fts(memory_id, title, content) VALUES (?, ?, ?)",
                    (memory_id, next_title or "", next_content),
                )
            connection.execute("DELETE FROM memory_embeddings WHERE memory_id = ?", (memory_id,))
        return self.get(memory_id)

    def delete(self, memory_id: str) -> bool:
        with self.database.connect() as connection:
            exists = connection.execute("SELECT 1 FROM memories WHERE id = ?", (memory_id,)).fetchone()
            if not exists:
                return False
            connection.execute("DELETE FROM memory_fts WHERE memory_id = ?", (memory_id,))
            connection.execute("DELETE FROM memory_embeddings WHERE memory_id = ?", (memory_id,))
            connection.execute("DELETE FROM memories WHERE id = ?", (memory_id,))
        return True

    def sparse_search(self, query: str, limit: int = 20) -> list[dict]:
        tokens = re.findall(r"\w+", query.casefold(), flags=re.UNICODE)
        if not tokens:
            return []
        match_query = " OR ".join(f'"{token.replace(chr(34), "")}"' for token in tokens[:24])
        with self.database.connect() as connection:
            rows = connection.execute(
                """
                SELECT f.memory_id, bm25(memory_fts) AS rank,
                       m.kind, m.title, m.content, m.source,
                       m.created_at, COALESCE(m.updated_at, m.created_at) AS updated_at
                FROM memory_fts f
                JOIN memories m ON m.id = f.memory_id
                WHERE memory_fts MATCH ? AND m.approved = 1
                ORDER BY rank ASC
                LIMIT ?
                """,
                (match_query, max(1, min(limit, 100))),
            ).fetchall()
        return [dict(row) for row in rows]

    def save_embedding(self, memory_id: str, model: str, vector: list[float]) -> None:
        if not vector:
            return
        with self.database.connect() as connection:
            connection.execute(
                """
                INSERT OR REPLACE INTO memory_embeddings(memory_id, model, dimensions, vector_json)
                VALUES (?, ?, ?, ?)
                """,
                (memory_id, model, len(vector), json.dumps(vector, separators=(",", ":"))),
            )

    def list_embeddings(self, model: str) -> list[dict]:
        with self.database.connect() as connection:
            rows = connection.execute(
                """
                SELECT m.id AS memory_id, m.kind, m.title, m.content, m.source,
                       m.created_at, COALESCE(m.updated_at, m.created_at) AS updated_at,
                       e.vector_json
                FROM memory_embeddings e
                JOIN memories m ON m.id = e.memory_id
                WHERE e.model = ? AND m.approved = 1
                """,
                (model,),
            ).fetchall()
        result: list[dict] = []
        for row in rows:
            item = dict(row)
            item["vector"] = json.loads(item.pop("vector_json"))
            result.append(item)
        return result

    def upsert_summary(
        self,
        conversation_id: str,
        *,
        summary: str,
        covered_through_message_id: str | None,
        token_estimate: int,
        provider: str | None,
        model: str | None,
    ) -> None:
        with self.database.connect() as connection:
            connection.execute(
                """
                INSERT INTO conversation_summaries(
                    conversation_id, summary, covered_through_message_id, token_estimate, provider, model, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    summary = excluded.summary,
                    covered_through_message_id = excluded.covered_through_message_id,
                    token_estimate = excluded.token_estimate,
                    provider = excluded.provider,
                    model = excluded.model,
                    updated_at = CURRENT_TIMESTAMP
                """,
                (conversation_id, summary, covered_through_message_id, token_estimate, provider, model),
            )

    def get_summary(self, conversation_id: str) -> dict | None:
        with self.database.connect() as connection:
            row = connection.execute(
                """
                SELECT conversation_id, summary, covered_through_message_id, token_estimate,
                       provider, model, updated_at
                FROM conversation_summaries WHERE conversation_id = ?
                """,
                (conversation_id,),
            ).fetchone()
        return dict(row) if row else None

    @staticmethod
    def _decode(row) -> dict:
        item = dict(row)
        item["approved"] = bool(item["approved"])
        try:
            item["metadata"] = json.loads(item.pop("metadata_json") or "{}")
        except json.JSONDecodeError:
            item["metadata"] = {}
        return item
