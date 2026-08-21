from __future__ import annotations

import json
import uuid
from typing import Any

from lumi_core.storage.database import Database

from .models import DeveloperProposal, DeveloperSessionView, DeveloperCheckResult


class DeveloperStore:
    def __init__(self, database: Database):
        self.database = database

    def create_session(
        self,
        *,
        goal: str,
        repository_root: str,
        base_branch: str,
        status: str,
        proposal: DeveloperProposal | None = None,
        proposed_diff: str | None = None,
        checks: list[str] | None = None,
        error: str | None = None,
    ) -> str:
        session_id = str(uuid.uuid4())
        with self.database.connect() as connection:
            connection.execute(
                """
                INSERT INTO developer_sessions(
                    id, goal, status, repository_root, base_branch, proposal_json,
                    proposed_diff, checks_json, error, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                """,
                (
                    session_id,
                    goal,
                    status,
                    repository_root,
                    base_branch,
                    proposal.model_dump_json() if proposal else None,
                    proposed_diff,
                    json.dumps(checks or []),
                    error,
                ),
            )
        self.add_event(session_id, "session_created", {"status": status})
        return session_id

    def update(self, session_id: str, **changes: Any) -> None:
        allowed = {
            "status",
            "branch_name",
            "proposal_json",
            "proposed_diff",
            "checks_json",
            "validation_json",
            "commit_sha",
            "pr_url",
            "error",
        }
        values = {key: value for key, value in changes.items() if key in allowed}
        if not values:
            return
        assignments = ", ".join(f"{key} = ?" for key in values)
        with self.database.connect() as connection:
            connection.execute(
                f"UPDATE developer_sessions SET {assignments}, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                (*values.values(), session_id),
            )

    def get(self, session_id: str) -> DeveloperSessionView | None:
        with self.database.connect() as connection:
            row = connection.execute(
                self._select_sql() + " WHERE id = ?",
                (session_id,),
            ).fetchone()
        return self._decode(row) if row else None

    def list(self, limit: int = 20) -> list[DeveloperSessionView]:
        with self.database.connect() as connection:
            rows = connection.execute(
                self._select_sql() + " ORDER BY updated_at DESC, rowid DESC LIMIT ?",
                (max(1, min(limit, 100)),),
            ).fetchall()
        return [self._decode(row) for row in rows]

    def add_event(self, session_id: str, event_type: str, payload: dict[str, Any] | None = None) -> None:
        with self.database.connect() as connection:
            connection.execute(
                "INSERT INTO developer_events(session_id, event_type, payload_json) VALUES (?, ?, ?)",
                (session_id, event_type, json.dumps(payload or {}, ensure_ascii=False)),
            )

    def events(self, session_id: str) -> list[dict]:
        with self.database.connect() as connection:
            rows = connection.execute(
                "SELECT id, session_id, event_type, payload_json, created_at FROM developer_events WHERE session_id = ? ORDER BY id",
                (session_id,),
            ).fetchall()
        result: list[dict] = []
        for row in rows:
            item = dict(row)
            item["payload"] = json.loads(item.pop("payload_json") or "{}")
            result.append(item)
        return result

    @staticmethod
    def _select_sql() -> str:
        return """
            SELECT id, goal, status, repository_root, base_branch, branch_name,
                   proposal_json, proposed_diff, checks_json, validation_json,
                   commit_sha, pr_url, error, created_at, updated_at
            FROM developer_sessions
        """

    @staticmethod
    def _decode(row) -> DeveloperSessionView:
        item = dict(row)
        proposal_raw = item.pop("proposal_json")
        checks_raw = item.pop("checks_json")
        validation_raw = item.pop("validation_json")
        item["proposal"] = DeveloperProposal.model_validate_json(proposal_raw) if proposal_raw else None
        item["checks"] = json.loads(checks_raw or "[]")
        item["validation"] = [
            DeveloperCheckResult.model_validate(value)
            for value in json.loads(validation_raw or "[]")
        ]
        return DeveloperSessionView.model_validate(item)
