# Implementation Status

Status vocabulary: `IDEA` → `SPEC` → `CODED` → `UNIT_TESTED` → `INTEGRATED` → `E2E_TESTED` → `RELEASED`.

| Capability | Status | Evidence / next gate |
|---|---|---|
| Split LumiCore / LumiMac layout | INTEGRATED | GitHub CI tests LumiCore independently on Linux and now builds + tests macOS platform support separately |
| Single AgentRuntime | INTEGRATED | request, model-turn, native tool-loop and permission-flow tests pass; macOS UI compiles |
| SQLite conversation persistence | UNIT_TESTED | restart/reopen durability test passes in CI; interactive app restart still pending |
| Visible storage Safe Mode | UNIT_TESTED | bootstrap failure test passes; UI compiles on macOS |
| OpenAI-compatible local model adapter | INTEGRATED | text + native single-tool-call transport are integrated with AgentRuntime under deterministic HTTP tests; live local-server run pending |
| Conversation UI | INTEGRATED | LumiMac builds successfully on macOS CI; interactive app run still pending |
| Tool runtime | INTEGRATED | typed registry/runtime merged; unknown tools and wire-name collisions fail closed; structured results include warnings/metadata |
| Permissions / PolicyEngine | INTEGRATED | exact opaque resource scopes, once/session grants and macOS Allow/Deny UI are wired and tested |
| Agent tool loop | INTEGRATED | native typed model decisions, explicit permission suspension/resume, denial flow, durable protocol history and hard step limit tested |
| File read tool | INTEGRATED | `file.readText@2` is bounded, UTF-8-only and accepts only broker-registered opaque `resourceID` values; raw model-supplied paths are not an authority boundary |
| Native local-model tool calling | INTEGRATED | OpenAI-compatible `tools` + `tool_calls`, provider call IDs, schema mapping and full protected round-trip tested; live llama.cpp/local-server E2E pending |
| macOS file access boundary | INTEGRATED | `NSOpenPanel → SecurityScopedFileCatalog → opaque resourceID → ToolRuntime → PermissionEngine`; persistent bookmarks and catalog reopen are tested on macOS CI |
| Knowledge ingestion / PDF | IDEA | next vertical slice: trusted selected resource → platform text extraction → provenance-preserving chunks → durable KnowledgeStore |
| Long-term user memory | IDEA | after Knowledge boundary is stable |
| Spreadsheet / Table Assistant | IDEA | after Knowledge/file ingestion is stable |
| TaskEngine | IDEA | after interactive tool execution is stable |
| Voice / Avatar | IDEA | after 1.0 core gates |
| DeveloperAgent / Darwin evals | IDEA | after 1.0 |
| Fleet / Swarm | DEFERRED | not before stable 1.x |

## Automated evidence

Current Linux Core CI covers **31 tests with zero failures**. The tested security/runtime invariants include:

- user input persists before model/tool execution;
- storage failure enters Safe Mode rather than silent RAM fallback;
- file reads require explicit exact-resource permission;
- one-time grants are consumed and session grants remain active;
- a grant for resource A cannot authorize resource B;
- unknown tools fail closed;
- duplicate tool registrations and model wire-name collisions fail closed;
- chat/model prose cannot create or imply a permission grant;
- file content does not reach the model before explicit approval;
- approval is bound to the exact pending operation ID;
- denial is persisted and the model can continue;
- tool loops stop at a hard step limit;
- tool failure does not erase the original durable user message;
- OpenAI-compatible tool schemas are emitted deterministically;
- native tool calls preserve the provider `tool_call_id`;
- malformed/unknown/multiple native tool calls fail closed;
- durable tool history reconstructs a valid `assistant tool_call → tool result` exchange;
- a native provider round-trip pauses for permission, executes only after approval, persists the result, and resumes the model;
- `UserFileResourceID` is encoded as an opaque JSON string rather than a filesystem-path object;
- a model-invented/unregistered user-file resource fails before Lumi can show an approval prompt.

macOS platform CI additionally covers **3 `SecurityScopedFileCatalog` tests with zero failures** and a successful LumiMac build:

- a selected file survives catalog reopen and remains readable through its persisted bookmark;
- registering the same selected file reuses its stable opaque resource identity;
- unknown resource IDs fail closed on the macOS broker as well as in Core.

## Golden Test 001 — durability

A conversation written through `AgentRuntime` must still exist after the SQLite store is closed and reopened.

Automated CI evidence passes. The remaining gate before calling this `E2E_TESTED` is an interactive macOS run of Lumi demonstrating restart persistence through the UI.

## Golden Test 002 — protected file action

A native model-requested `file.readText` action must pause before reading, expose the exact resource/capability for approval, execute only after an explicit decision, persist protocol-complete tool history, and let the model continue.

The model/runtime path is covered automatically using the real `OpenAICompatibleProvider` with an injected deterministic HTTP transport:

`native tool_call → AgentRuntime → PermissionEngine → approval → file.readText@2 → UserFileAccessBroker → durable ToolHistoryEvent → second native model turn → final response`.

The filesystem authority boundary is tested independently on macOS:

`explicit NSOpenPanel selection → security-scoped bookmark → opaque resourceID → catalog reopen → bounded broker read`.

The remaining E2E gate is one real interactive macOS run against the chosen local model server, using a user-selected file through `NSOpenPanel`. No capability is marked `E2E_TESTED` solely from mocked HTTP or automated bookmark tests.
