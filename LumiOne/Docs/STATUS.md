# Implementation Status

Status vocabulary: `IDEA` → `SPEC` → `CODED` → `UNIT_TESTED` → `INTEGRATED` → `E2E_TESTED` → `RELEASED`.

| Capability | Status | Evidence / next gate |
|---|---|---|
| Split LumiCore / LumiMac layout | INTEGRATED | GitHub CI builds LumiMac on macOS and tests LumiCore independently on Linux |
| Single AgentRuntime | UNIT_TESTED | Core tests exercise the request/persistence flow |
| SQLite conversation persistence | UNIT_TESTED | restart/reopen durability test passes in CI |
| Visible storage Safe Mode | UNIT_TESTED | bootstrap failure test passes; UI compiles on macOS |
| OpenAI-compatible local model adapter | CODED | live local-server integration test pending |
| Conversation UI | INTEGRATED | LumiMac package builds successfully on macOS CI; interactive app run still pending |
| Tool runtime | SPEC | Phase 2 vertical slice starts next |
| Permissions / PolicyEngine | SPEC | Phase 2 vertical slice starts next |
| Knowledge ingestion / PDF | IDEA | after Tool Runtime |
| Long-term user memory | IDEA | after Knowledge boundary is stable |
| Spreadsheet / Table Assistant | IDEA | after Tool Runtime |
| TaskEngine | IDEA | after Tool Runtime |
| Voice / Avatar | IDEA | after 1.0 core gates |
| DeveloperAgent / Darwin evals | IDEA | after 1.0 |
| Fleet / Swarm | DEFERRED | not before stable 1.x |

## Golden Test 001 — durability

A conversation written through `AgentRuntime` must still exist after the SQLite store is closed and reopened.

Automated CI evidence now passes on the Lumi One rebuild branch. The remaining gate before calling Phase 1 `E2E_TESTED` is an interactive macOS run of `Lumi.app` that demonstrates the same restart persistence through the UI.

Lumi One may now begin the Tool Runtime / Permission Engine slice, but Phase 1 remains open until that macOS E2E evidence exists.
