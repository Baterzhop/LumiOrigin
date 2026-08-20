# Implementation Status

Status vocabulary: `IDEA` → `SPEC` → `CODED` → `UNIT_TESTED` → `INTEGRATED` → `E2E_TESTED` → `RELEASED`.

| Capability | Status | Evidence / next gate |
|---|---|---|
| Split LumiCore / LumiMac layout | CODED | CI must build both independently |
| Single AgentRuntime | CODED | Core unit test exercises send flow |
| SQLite conversation persistence | CODED | Reopen test must pass in CI |
| Visible storage Safe Mode | CODED | macOS UI build + failure test pending |
| OpenAI-compatible local model adapter | CODED | live local-server integration test pending |
| Conversation UI | CODED | macOS CI build pending |
| Tool runtime | SPEC | not implemented in this phase |
| Permissions / PolicyEngine | SPEC | next vertical slice |
| Knowledge ingestion / PDF | IDEA | after Tool Runtime |
| Long-term user memory | IDEA | after Knowledge boundary is stable |
| Spreadsheet / Table Assistant | IDEA | after Tool Runtime |
| TaskEngine | IDEA | after Tool Runtime |
| Voice / Avatar | IDEA | after 1.0 core gates |
| DeveloperAgent / Darwin evals | IDEA | after 1.0 |
| Fleet / Swarm | DEFERRED | not before stable 1.x |

## Current Golden Test 001

A conversation written through `AgentRuntime` must still exist after the SQLite store is closed and reopened.

This is intentionally a small gate. Lumi One does not advance to self-learning, memory evolution, tools, or avatar work until basic durability is proven.
