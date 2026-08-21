# Lumi V4 Streaming Event Protocol

Milestone M1 uses Server-Sent Events (SSE) from `POST /v1/chat/stream`.

Each event contains a JSON object in the SSE `data:` field and an SSE event name matching the JSON `type`.

## Lifecycle

```text
started
  ↓
delta × N
  ↓
completed | cancelled | error
```

## started

```json
{
  "type": "started",
  "generation_id": "...",
  "conversation_id": "..."
}
```

The client stores `generation_id` so a Stop action can call:

```text
POST /v1/generations/{generation_id}/cancel
```

## delta

Contains one streamed text fragment plus provider/model metadata.

## completed

Contains the durable assistant `message_id`, full final content, provider/model, fallback/error metadata, and `finish_reason`.

## cancelled

If the user cancels after visible tokens were produced, the visible partial assistant message is persisted with `finish_reason=cancelled`. If no assistant content was emitted, only the user message remains.

## error

A partial visible answer can be persisted with `finish_reason=error`. Provider failures before any primary token may switch to the structured fallback provider.

## Trust boundary

SSE is transport only. Client UI state must be driven by structured fields, never by parsing natural-language assistant text.
