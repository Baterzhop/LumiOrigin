# Lumi V4 Memory Contract

## Purpose

M4 gives Lumi durable, inspectable memory without turning every chat message into permanent profile data. The memory subsystem is deliberately explicit: a durable memory is created only through an action that carries user approval, and every stored item can be listed, edited, and hard-deleted.

## Memory classes

Lumi separates three forms of context:

1. **Recent working context** — recent user/assistant messages selected by an approximate token budget.
2. **Conversation summary** — a compact record of older dialogue. It is generated only when the recent-context budget would otherwise be exceeded. If the configured model is unavailable, Lumi uses a deterministic extractive fallback rather than dropping the older context silently.
3. **Durable memory** — user-approved facts, preferences, project notes, or other explicitly saved items that can be recalled across conversations.

Durable memory is not a system prompt. It may be stale or context-specific and therefore never overrides the current user request or higher-priority policy.

## Storage

SQLite remains the canonical state store.

- `memories` stores the user-visible record.
- `memory_fts` provides lexical FTS5 retrieval.
- `memory_embeddings` stores optional local embedding vectors by model name.
- `conversation_summaries` stores one current compact summary per conversation and records the message through which that summary applies.

Deleting a durable memory removes the row, its FTS entry, and its stored embeddings in the same operation. Tests assert that deleted memory can no longer be retrieved through either path.

## Retrieval

Memory recall uses two independent rankings when local embeddings are enabled:

```text
query
 ├─ SQLite FTS5
 └─ local embedding cosine scan
          ↓
     weighted RRF
          ↓
     top memory items
```

Raw FTS and cosine scores are never added directly. Reciprocal-rank fusion avoids comparing incompatible score scales.

If the local embedding provider is offline, memory remains available through FTS5.

## Context budgeting

`ConversationContextManager` estimates prompt tokens deterministically and keeps recent dialogue under a configured recent-message budget. Older messages are compacted into a summary, which is then included separately from recent turns.

Environment controls:

```bash
LUMI_CONTEXT_MAX_INPUT_TOKENS=6000
LUMI_CONTEXT_RECENT_TOKENS=3500
LUMI_CONTEXT_SUMMARY_TOKENS=800
LUMI_MEMORY_RECALL_K=4
```

The estimator is an approximation for context management, not a billing/tokenizer authority. Provider-specific tokenizers can replace it later behind the same contract.

## API

```text
GET    /v1/memories
POST   /v1/memories
PATCH  /v1/memories/{memory_id}
DELETE /v1/memories/{memory_id}
POST   /v1/memories/search
GET    /v1/conversations/{conversation_id}/summary
```

Creating memory requires `approved_by_user=true`. The current agent tool registry has no autonomous memory-write tool, so the planner cannot silently persist new durable memory.

## UI

The macOS client exposes a Memory manager where the user can:

- inspect all durable memories;
- create a memory deliberately;
- edit its title, type, and content;
- permanently delete it;
- see whether semantic recall is available.

Chat responses also surface which memory items were recalled, separately from RAG citations.

## Evaluation and limits

CI includes a deterministic memory-retrieval regression corpus and thresholds for Recall@3 and reciprocal rank, plus deletion tests. This catches regressions in storage/retrieval plumbing. It does **not** prove real-world memory relevance quality; representative multilingual and long-horizon evaluation is required before beta.

M4 does not automatically infer sensitive profile facts, does not silently promote conversation text to durable memory, and does not treat summaries as authoritative truth.
