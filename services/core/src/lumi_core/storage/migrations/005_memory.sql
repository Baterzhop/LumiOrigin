ALTER TABLE memories ADD COLUMN title TEXT;
ALTER TABLE memories ADD COLUMN source TEXT NOT NULL DEFAULT 'user';
ALTER TABLE memories ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE memories ADD COLUMN updated_at TEXT;
UPDATE memories SET updated_at = created_at WHERE updated_at IS NULL;

CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
    memory_id UNINDEXED,
    title,
    content,
    tokenize = 'unicode61'
);

INSERT INTO memory_fts(memory_id, title, content)
SELECT id, COALESCE(title, ''), content
FROM memories
WHERE approved = 1
  AND id NOT IN (SELECT memory_id FROM memory_fts);

CREATE TABLE IF NOT EXISTS memory_embeddings (
    memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    model TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    vector_json TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(memory_id, model)
);

CREATE TABLE IF NOT EXISTS conversation_summaries (
    conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
    summary TEXT NOT NULL,
    covered_through_message_id TEXT,
    token_estimate INTEGER NOT NULL DEFAULT 0,
    provider TEXT,
    model TEXT,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_memories_approved_updated
ON memories(approved, updated_at);
