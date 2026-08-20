from __future__ import annotations

from contextlib import contextmanager
from importlib import resources
from pathlib import Path
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
            connection.execute(
                "INSERT INTO conversations(id, title) VALUES (?, ?)",
                (conversation_id, title),
            )
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
            connection.execute(
                "UPDATE conversations SET updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                (conversation_id,),
            )
        return message_id

    def list_messages(self, conversation_id: str, limit: int = 30) -> list[dict]:
        limit = max(1, min(limit, 200))
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT id, role, content, provider, model, generation_id, finish_reason, error, created_at FROM messages WHERE conversation_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?",
                (conversation_id, limit),
            ).fetchall()
        return [dict(row) for row in reversed(rows)]
