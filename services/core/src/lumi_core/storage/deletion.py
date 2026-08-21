from __future__ import annotations

from lumi_core.storage.database import Database


def delete_conversation(database: Database, conversation_id: str) -> bool:
    """Delete one conversation and its cascading messages/summaries.

    Tasks intentionally retain their durable audit history because the schema uses
    `ON DELETE SET NULL` for the optional conversation association.
    """

    with database.connect() as connection:
        cursor = connection.execute("DELETE FROM conversations WHERE id = ?", (conversation_id,))
        return cursor.rowcount > 0


def delete_document(database: Database, document_id: str) -> bool:
    """Delete one indexed document and all derived retrieval state atomically."""

    with database.connect() as connection:
        exists = connection.execute("SELECT 1 FROM documents WHERE id = ?", (document_id,)).fetchone()
        if exists is None:
            return False
        connection.execute(
            "DELETE FROM chunk_embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE document_id = ?)",
            (document_id,),
        )
        # FTS5 is a separate virtual table and therefore must be cleaned explicitly.
        connection.execute("DELETE FROM chunk_fts WHERE document_id = ?", (document_id,))
        connection.execute("DELETE FROM chunks WHERE document_id = ?", (document_id,))
        connection.execute("DELETE FROM documents WHERE id = ?", (document_id,))
        return True
