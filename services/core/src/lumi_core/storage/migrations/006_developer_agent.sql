CREATE TABLE IF NOT EXISTS developer_sessions (
    id TEXT PRIMARY KEY,
    goal TEXT NOT NULL,
    status TEXT NOT NULL,
    repository_root TEXT NOT NULL,
    base_branch TEXT NOT NULL,
    branch_name TEXT,
    proposal_json TEXT,
    proposed_diff TEXT,
    checks_json TEXT NOT NULL DEFAULT '[]',
    validation_json TEXT NOT NULL DEFAULT '[]',
    commit_sha TEXT,
    pr_url TEXT,
    error TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS developer_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES developer_sessions(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_developer_sessions_status_updated
ON developer_sessions(status, updated_at);

CREATE INDEX IF NOT EXISTS idx_developer_events_session_created
ON developer_events(session_id, created_at);
