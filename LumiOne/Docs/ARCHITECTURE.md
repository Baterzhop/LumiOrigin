# Lumi One — Architecture Freeze 0.1

## Product rule

Lumi One is a local-first personal AI application. The first objective is reliability, not autonomous self-evolution.

## Runtime boundary

```text
LumiMac
  ↓
AgentRuntime
  ├─ ConversationStore
  ├─ ModelProvider
  ├─ future ContextService
  ├─ future ToolService
  └─ future PolicyEngine
```

`AgentRuntime` is the only execution controller. A model can return language or, in later phases, structured action requests. Side effects remain deterministic application code.

## Persistence

Phase 1 stores conversations and messages in SQLite. Storage failure is not replaced with an invisible in-memory repository. Startup returns explicit Safe Mode and disables writes.

## Legacy mapping

The historical `AeonCore`, `Dual Core`, `MetaLumi`, `Reflector`, and `SelfCoder` concepts are design history, not production runtime components.

Useful behavior will be migrated as requirements:

- `Reflector` → evaluation/observability later.
- `SelfCoder` / `SelfCreator` → patch-proposal DeveloperAgent after 1.0.
- `LongArcMemory` → temporal episodic/semantic memory.
- `AI Table Assistant` → typed spreadsheet tools + DataWorker.
- `Watcher` → scoped EventService.
- `TrustShield` → capability-based PolicyEngine.

## Non-negotiable quality rules

1. No feature without a vertical end-to-end test.
2. No silent fallback for durable state.
3. No prompt can grant permissions.
4. Tool outputs and documents are untrusted data.
5. No direct self-modification of the running source tree.
6. `CODED` does not mean `INTEGRATED`; `INTEGRATED` does not mean `RELEASED`.

## Phase 1 gate

The following must pass before Memory/Tools expansion:

1. Build `LumiCore` on CI.
2. Build `LumiMac` on macOS CI.
3. Send a message through `AgentRuntime`.
4. Persist user and assistant messages in SQLite.
5. Reopen the database and recover the conversation.
6. Deliberately break storage startup and show visible Safe Mode.
