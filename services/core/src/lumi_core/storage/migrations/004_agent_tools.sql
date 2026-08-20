ALTER TABLE tasks ADD COLUMN max_steps INTEGER NOT NULL DEFAULT 8;
ALTER TABLE tasks ADD COLUMN max_tool_calls INTEGER NOT NULL DEFAULT 6;
ALTER TABLE tasks ADD COLUMN deadline_at TEXT;
ALTER TABLE tasks ADD COLUMN result_text TEXT;
ALTER TABLE tasks ADD COLUMN error TEXT;
ALTER TABLE tasks ADD COLUMN waiting_tool_call_id TEXT;

ALTER TABLE tool_calls ADD COLUMN decision_reason TEXT;
ALTER TABLE tool_calls ADD COLUMN error TEXT;
ALTER TABLE tool_calls ADD COLUMN started_at TEXT;
ALTER TABLE tool_calls ADD COLUMN finished_at TEXT;
ALTER TABLE tool_calls ADD COLUMN updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP;

CREATE INDEX IF NOT EXISTS idx_tasks_status_updated ON tasks(status, updated_at);
CREATE INDEX IF NOT EXISTS idx_tool_calls_task_created ON tool_calls(task_id, created_at);
