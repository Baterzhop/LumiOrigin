from __future__ import annotations

from fastapi import APIRouter, HTTPException

from lumi_core.storage.database import Database
from lumi_core.storage.deletion import delete_conversation, delete_document


def build_data_management_router(database: Database) -> APIRouter:
    router = APIRouter()

    @router.delete("/v1/conversations/{conversation_id}")
    def remove_conversation(conversation_id: str) -> dict:
        if not delete_conversation(database, conversation_id):
            raise HTTPException(status_code=404, detail="conversation_not_found")
        return {"ok": True, "conversation_id": conversation_id, "deleted": True}

    @router.delete("/v1/knowledge/documents/{document_id}")
    def remove_document(document_id: str) -> dict:
        if not delete_document(database, document_id):
            raise HTTPException(status_code=404, detail="document_not_found")
        return {"ok": True, "document_id": document_id, "deleted": True}

    return router
