from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from importlib import resources
from pathlib import Path
import json
import re
import sqlite3
import uuid


class Database:
    def __init__(self, path: Path | str):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    @contextmanager
    def connect(self):
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        try:
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def migrate(self) -> None:
        migration_dir = resources.files("lumi_core.storage.migrations")
        files = sorted(p for p in migration_dir.iterdir() if p.name.endswith(".sql"))
        with self.connect() as connection:
            connection.execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
            )
            applied = {row[0] for row in connection.execute("SELECT version FROM schema_migrations")}
            for migration in files:
                version = int(migration.name.split("_", 1)[0])
                if version in applied:
                    continue
                sql = migration.read_text(encoding="utf-8")
                connection.executescript(sql)
                connection.execute("INSERT INTO schema_migrations(version) VALUES (?)", (version,))

    def create_conversation(self, title: str | None = None, conversation_id: str | None = None) -> str:
        conversation_id = conversation_id or str(uuid.uuid4())
        with self.connect() as connection:
            connection.execute("INSERT INTO conversations(id, title) VALUES (?, ?)", (conversation_id, title))
        return conversation_id

    def conversation_exists(self, conversation_id: str) -> bool:
        with self.connect() as connection:
            row = connection.execute("SELECT 1 FROM conversations WHERE id = ?", (conversation_id,)).fetchone()
        return row is not None

    def add_message(
        self,
        conversation_id: str,
        role: str,
        content: str,
        *,
        provider: str | None = None,
        model: str | None = None,
        generation_id: str | None = None,
        finish_reason: str | None = None,
        error: str | None = None,
    ) -> str:
        message_id = str(uuid.uuid4())
        with self.connect() as connection:
            connection.execute(
                "INSERT INTO messages(id, conversation_id, role, content, provider, model, generation_id, finish_reason, error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (message_id, conversation_id, role, content, provider, model, generation_id, finish_reason, error),
            )
            connection.execute("UPDATE conversations SET updated_at = CURRENT_TIMESTAMP WHERE id = ?", (conversation_id,))
        return message_id

    def list_messages(self, conversation_id: str, limit: int = 30) -> list[dict]:
        limit = max(1, min(limit, 200))
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT id, role, content, provider, model, generation_id, finish_reason, error, created_at FROM messages WHERE conversation_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?",
                (conversation_id, limit),
            ).fetchall()
        return [dict(row) for row in reversed(rows)]

    def create_task(
        self,
        goal: str,
        *,
        conversation_id: str | None = None,
        max_steps: int = 8,
        max_tool_calls: int = 6,
        max_seconds: int = 120,
    ) -> str:
        if conversation_id is not None and not self.conversation_exists(conversation_id):
            raise ValueError("conversation_not_found")
        task_id = str(uuid.uuid4())
        deadline = (datetime.now(timezone.utc) + timedelta(seconds=max_seconds)).isoformat()
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO tasks(id, conversation_id, goal, status, max_steps, max_tool_calls, deadline_at)
                VALUES (?, ?, ?, 'running', ?, ?, ?)
                """,
                (task_id, conversation_id, goal, max_steps, max_tool_calls, deadline),
            )
        return task_id

    def get_task(self, task_id: str) -> dict | None:
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT id, conversation_id, goal, status, step_count, max_steps, max_tool_calls,
                       deadline_at, result_text, error, waiting_tool_call_id, created_at, updated_at
                FROM tasks WHERE id = ?
                """,
                (task_id,),
            ).fetchone()
        return dict(row) if row else None

    def update_task(self, task_id: str, **changes) -> None:
        allowed = {
            "status",
            "step_count",
            "result_text",
            "error",
            "waiting_tool_call_id",
        }
        values = {key: value for key, value in changes.items() if key in allowed}
        if not values:
            return
        assignments = ", ".join(f"{key} = ?" for key in values)
        with self.connect() as connection:
            connection.execute(
                f"UPDATE tasks SET {assignments}, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                (*values.values(), task_id),
            )

    def create_tool_call(
        self,
        task_id: str,
        tool_name: str,
        arguments: dict,
        *,
        risk: str,
        status: str,
        decision_reason: str | None = None,
        error: str | None = None,
    ) -> str:
        call_id = str(uuid.uuid4())
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO tool_calls(id, task_id, tool_name, arguments_json, risk, status, decision_reason, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (call_id, task_id, tool_name, json.dumps(arguments, ensure_ascii=False), risk, status, decision_reason, error),
            )
        return call_id

    def get_tool_call(self, tool_call_id: str) -> dict | None:
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT id, task_id, tool_name, arguments_json, risk, status, result_json, decision_reason,
                       error, started_at, finished_at, created_at, updated_at
                FROM tool_calls WHERE id = ?
                """,
                (tool_call_id,),
            ).fetchone()
        if not row:
            return None
        item = dict(row)
        item["arguments"] = json.loads(item.pop("arguments_json"))
        item["result"] = json.loads(item.pop("result_json")) if item.get("result_json") else None
        return item

    def list_tool_calls(self, task_id: str) -> list[dict]:
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT id, task_id, tool_name, arguments_json, risk, status, result_json, decision_reason,
                       error, started_at, finished_at, created_at, updated_at
                FROM tool_calls WHERE task_id = ? ORDER BY created_at, rowid
                """,
                (task_id,),
            ).fetchall()
        result: list[dict] = []
        for row in rows:
            item = dict(row)
            item["arguments"] = json.loads(item.pop("arguments_json"))
            item["result"] = json.loads(item.pop("result_json")) if item.get("result_json") else None
            result.append(item)
        return result

    def count_tool_calls(self, task_id: str) -> int:
        with self.connect() as connection:
            row = connection.execute("SELECT COUNT(*) FROM tool_calls WHERE task_id = ?", (task_id,)).fetchone()
        return int(row[0] if row else 0)

    def update_tool_call(
        self,
        tool_call_id: str,
        *,
        status: str | None = None,
        result: object | None = None,
        decision_reason: str | None = None,
        error: str | None = None,
        started: bool = False,
        finished: bool = False,
    ) -> None:
        assignments: list[str] = []
        values: list[object] = []
        if status is not None:
            assignments.append("status = ?")
            values.append(status)
        if result is not None:
            assignments.append("result_json = ?")
            values.append(json.dumps(result, ensure_ascii=False))
        if decision_reason is not None:
            assignments.append("decision_reason = ?")
            values.append(decision_reason)
        if error is not None:
            assignments.append("error = ?")
            values.append(error)
        if started:
            assignments.append("started_at = CURRENT_TIMESTAMP")
        if finished:
            assignments.append("finished_at = CURRENT_TIMESTAMP")
        assignments.append("updated_at = CURRENT_TIMESTAMP")
        with self.connect() as connection:
            connection.execute(
                f"UPDATE tool_calls SET {', '.join(assignments)} WHERE id = ?",
                (*values, tool_call_id),
            )

    def find_document_by_hash(self, content_hash: str) -> dict | None:
        with self.connect() as connection:
            row = connection.execute(
                "SELECT id, source, title, content_hash, language, mime_type, metadata_json, created_at, updated_at FROM documents WHERE content_hash = ? ORDER BY created_at LIMIT 1",
                (content_hash,),
            ).fetchone()
        return dict(row) if row else None

    def create_document(
        self,
        *,
        document_id: str,
        source: str,
        title: str | None,
        content_hash: str,
        language: str | None,
        mime_type: str | None,
        metadata: dict | None = None,
    ) -> None:
        with self.connect() as connection:
            connection.execute(
                "INSERT INTO documents(id, source, title, content_hash, language, mime_type, metadata_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (document_id, source, title, content_hash, language, mime_type, json.dumps(metadata or {}, ensure_ascii=False)),
            )

    def replace_document_chunks(self, document_id: str, chunks: list[dict]) -> None:
        with self.connect() as connection:
            connection.execute(
                "DELETE FROM chunk_embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE document_id = ?)",
                (document_id,),
            )
            connection.execute("DELETE FROM chunk_fts WHERE document_id = ?", (document_id,))
            connection.execute("DELETE FROM chunks WHERE document_id = ?", (document_id,))
            title_row = connection.execute("SELECT COALESCE(title, '') FROM documents WHERE id = ?", (document_id,)).fetchone()
            title = title_row[0] if title_row else ""
            for chunk in chunks:
                connection.execute(
                    "INSERT INTO chunks(id, document_id, ordinal, text, page, section, content_hash, token_count, metadata_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        chunk["id"], document_id, chunk["ordinal"], chunk["text"], chunk.get("page"), chunk.get("section"),
                        chunk["content_hash"], chunk.get("token_count"), json.dumps(chunk.get("metadata") or {}, ensure_ascii=False),
                    ),
                )
                connection.execute(
                    "INSERT INTO chunk_fts(chunk_id, document_id, title, text) VALUES (?, ?, ?, ?)",
                    (chunk["id"], document_id, title, chunk["text"]),
                )
            connection.execute("UPDATE documents SET updated_at = CURRENT_TIMESTAMP WHERE id = ?", (document_id,))

    def get_chunks_for_document(self, document_id: str) -> list[dict]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT id, document_id, ordinal, text, page, section, content_hash, token_count, metadata_json FROM chunks WHERE document_id = ? ORDER BY ordinal",
                (document_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    def save_embeddings(self, model: str, vectors: list[tuple[str, list[float]]]) -> None:
        with self.connect() as connection:
            for chunk_id, vector in vectors:
                if not vector:
                    continue
                connection.execute(
                    "INSERT OR REPLACE INTO chunk_embeddings(chunk_id, model, dimensions, vector_json) VALUES (?, ?, ?, ?)",
                    (chunk_id, model, len(vector), json.dumps(vector, separators=(",", ":"))),
                )

    def embedding_count(self, document_id: str, model: str) -> int:
        with self.connect() as connection:
            row = connection.execute(
                "SELECT COUNT(*) FROM chunk_embeddings e JOIN chunks c ON c.id = e.chunk_id WHERE c.document_id = ? AND e.model = ?",
                (document_id, model),
            ).fetchone()
        return int(row[0] if row else 0)

    def list_embeddings(self, model: str) -> list[dict]:
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT c.id AS chunk_id, c.document_id, c.text, c.page, c.section,
                       d.title, d.source, e.vector_json
                FROM chunk_embeddings e
                JOIN chunks c ON c.id = e.chunk_id
                JOIN documents d ON d.id = c.document_id
                WHERE e.model = ?
                """,
                (model,),
            ).fetchall()
        result: list[dict] = []
        for row in rows:
            item = dict(row)
            item["vector"] = json.loads(item.pop("vector_json"))
            result.append(item)
        return result

    def search_chunks_fts(self, query: str, limit: int = 30) -> list[dict]:
        tokens = re.findall(r"\w+", query.lower(), flags=re.UNICODE)
        if not tokens:
            return []
        match_query = " OR ".join(f'"{token.replace(chr(34), "")}"' for token in tokens[:24])
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT f.chunk_id, f.document_id, f.title, f.text, bm25(chunk_fts) AS rank,
                       c.page, c.section, d.source
                FROM chunk_fts f
                JOIN chunks c ON c.id = f.chunk_id
                JOIN documents d ON d.id = f.document_id
                WHERE chunk_fts MATCH ?
                ORDER BY rank ASC
                LIMIT ?
                """,
                (match_query, max(1, min(limit, 100))),
            ).fetchall()
        return [dict(row) for row in rows]

    def list_documents(self, limit: int = 100) -> list[dict]:
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT d.id, d.source, d.title, d.content_hash, d.language, d.mime_type, d.created_at, d.updated_at,
                       COUNT(c.id) AS chunk_count
                FROM documents d
                LEFT JOIN chunks c ON c.document_id = d.id
                GROUP BY d.id
                ORDER BY d.updated_at DESC
                LIMIT ?
                """,
                (max(1, min(limit, 500)),),
            ).fetchall()
        return [dict(row) for row in rows]
