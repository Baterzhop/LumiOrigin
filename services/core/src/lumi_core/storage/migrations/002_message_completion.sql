ALTER TABLE messages ADD COLUMN generation_id TEXT;
ALTER TABLE messages ADD COLUMN finish_reason TEXT;
ALTER TABLE messages ADD COLUMN error TEXT;

CREATE INDEX IF NOT EXISTS idx_messages_generation ON messages(generation_id);
