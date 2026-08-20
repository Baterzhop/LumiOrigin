# Implementation Status

Status vocabulary: `IDEA` → `SPEC` → `CODED` → `UNIT_TESTED` → `INTEGRATED` → `E2E_TESTED` → `RELEASED`.

| Capability | Status | Evidence / next gate |
|---|---|---|
| Split LumiCore / LumiMac layout | INTEGRATED | GitHub CI builds LumiMac on macOS and tests LumiCore independently on Linux |
| Single AgentRuntime | INTEGRATED | request, model-turn, tool-loop and permission-flow tests pass; macOS UI compiles |
| SQLite conversation persistence | UNIT_TESTED | restart/reopen durability test passes in CI; interactive app restart still pending |
| Visible storage Safe Mode | UNIT_TESTED | bootstrap failure test passes; UI compiles on macOS |
| OpenAI-compatible local model adapter | CODED | text chat transport exists; native tool-call transport and live local-server integration pending |
| Conversation UI | INTEGRATED | LumiMac package builds successfully on macOS CI; interactive app run still pending |
| Tool runtime | INTEGRATED | typed registry/runtime merged; unknown tools fail closed; AgentRuntime routes actions through it |
| Permissions / PolicyEngine | INTEGRATED | exact resource scopes, once/session grants and macOS Allow/Deny UI are wired and tested |
| Agent tool loop | INTEGRATED | typed model decisions, explicit permission suspension/resume, denial flow and hard step limit tested |
| File read tool | INTEGRATED | `file.readText@1` is bounded, UTF-8-only and exact-file permission scoped |
| Native local-model tool calling | SPEC | next vertical slice: OpenAI/llama.cpp `tool_calls` transport with schema mapping |
| Knowledge ingestion / PDF | IDEA | after native tool transport and file picker boundary |
| Long-term user memory | IDEA | after Knowledge boundary is stable |
| Spreadsheet / Table Assistant | IDEA | after file/tool vertical slice is live end-to-end |
| TaskEngine | IDEA | after interactive tool execution is stable |
| Voice / Avatar | IDEA | after 1.0 core gates |
| DeveloperAgent / Darwin evals | IDEA | after 1.0 |
| Fleet / Swarm | DEFERRED | not before stable 1.x |

## Automated evidence

Current Core CI covers 18 tests with zero failures. The tested security/runtime invariants include:

- user input persists before model/tool execution;
- storage failure enters Safe Mode rather than silent RAM fallback;
- file reads require explicit exact-resource permission;
- one-time grants are consumed and session grants remain active;
- a grant for file A cannot authorize file B;
- unknown tools fail closed;
- chat text cannot approve a pending action;
- file content does not reach the model before explicit approval;
- approval is bound to the exact pending operation ID;
- denial is persisted and the model can continue;
- tool loops stop at a hard step limit;
- tool failure does not erase the original durable user message.

## Golden Test 001 — durability

A conversation written through `AgentRuntime` must still exist after the SQLite store is closed and reopened.

Automated CI evidence passes. The remaining gate before calling Phase 1 `E2E_TESTED` is an interactive macOS run of `Lumi.app` demonstrating restart persistence through the UI.

## Golden Test 002 — protected file action

A model-requested `file.readText` action must pause before reading, show the exact resource/capability to the user, execute only after an explicit UI decision, persist the tool result, and then let the model continue.

The model-independent runtime and UI boundary is integrated and tested. The next gate is native local-model `tool_calls` transport so this path can run end-to-end with the real local model rather than only scripted test providers.
