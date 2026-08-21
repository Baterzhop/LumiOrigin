# Implementation Status

Status vocabulary: `IDEA` → `SPEC` → `CODED` → `UNIT_TESTED` → `INTEGRATED` → `E2E_TESTED` → `RELEASED`.

| Capability | Status | Evidence / next gate |
|---|---|---|
| Split LumiCore / LumiMac layout | INTEGRATED | GitHub CI tests LumiCore independently on Linux and builds + tests macOS platform support separately |
| Single AgentRuntime | INTEGRATED | request, model-turn, native tool-loop, combined Knowledge + Memory context, SpreadsheetTools and permission-flow tests pass; macOS UI compiles |
| SQLite conversation persistence | UNIT_TESTED | restart/reopen durability test passes in CI; interactive app restart still pending |
| Visible storage Safe Mode | UNIT_TESTED | bootstrap failure test passes; UI compiles on macOS |
| OpenAI-compatible local model adapter | INTEGRATED | text + native single-tool-call transport + lower-authority Knowledge/Memory evidence envelopes are integrated under deterministic HTTP tests; live local-server run pending |
| Conversation UI | INTEGRATED | LumiMac builds successfully on macOS CI; citations, Memory controls, selected-file surfaces and bounded table preview are wired; interactive app run still pending |
| Tool runtime | INTEGRATED | typed registry/runtime, native tool calls, transient model-visible results vs privacy-redacted durable results, warnings/metadata and fail-closed registration are tested |
| Permissions / PolicyEngine | INTEGRATED | exact opaque resources + exact operation details are enforced; persistent Memory and user-file mutations are forced to one-operation approval |
| Agent tool loop | INTEGRATED | native typed model decisions, explicit permission suspension/resume, denial flow, durable protocol history, transient sensitive tool results and hard step limit tested |
| File read tool | INTEGRATED | `file.readText@2` is bounded, UTF-8-only and accepts only broker-registered opaque `resourceID` values |
| Native local-model tool calling | INTEGRATED | OpenAI-compatible `tools` + `tool_calls`, provider call IDs, schema mapping and protected round-trips tested; live llama.cpp/local-server E2E pending |
| macOS file access boundary | INTEGRATED | `NSOpenPanel/NSSavePanel → SecurityScopedFileCatalog → opaque resourceID`; bookmarks survive reopen, writes require an explicitly registered empty destination and silent overwrite is rejected |
| Knowledge ingestion / PDF | INTEGRATED | trusted opaque resource → PDFKit extraction → page provenance → deterministic bounded chunks → transactional SQLite KnowledgeStore; reopen and rollback tests pass |
| Grounded knowledge retrieval / citations | INTEGRATED | deterministic lexical retrieval, Recall@k/MRR evaluation, bounded untrusted evidence context, stable permission-pause reuse and fail-closed citation validation are wired into LumiMac |
| Long-term user memory | INTEGRATED | transactional SQLite store, revision/provenance metadata, exact-operation permission-gated remember/forget, bounded retrieval and visible LumiMac inspect/edit/forget UI |
| SpreadsheetTools | INTEGRATED | deterministic CSV/TSV inspect/profile/range/query/filter/sort plus immutable preview → exact one-time approval → write-to-new-output; formula-injection defense and history redaction tested |
| TaskEngine | IDEA | next vertical slice: durable task state machine, SQLite task store, audit events and visible user control |
| Automation / Scheduler | IDEA | after TaskEngine is durable and restart-safe |
| Voice / Avatar | IDEA | after 1.0 core gates |
| DeveloperAgent / Darwin evals | IDEA | after 1.0; patch proposals only, never live self-rewriting |
| Fleet / Swarm | DEFERRED | not before stable 1.x |

## Automated evidence

Current Phase 8 code/test head: `9ba4397bbec8a285c34594334f67fac4811e6e82`.

- Linux LumiCore: **98 tests, 0 failures** on Swift 6.3.3.
- macOS LumiMacSupport: **8 tests, 0 failures**.
- LumiMac: **successful macOS build**.
- The only CI warning is the external GitHub Actions Node runtime deprecation emitted by `actions/checkout@v4`; Lumi code compiles without the prior Spreadsheet mutation warning.

### Phase 8 — SpreadsheetTools invariants

- the legacy “AI Table Assistant” is not a separate agent/core; spreadsheets are ordinary typed tools controlled by `AgentRuntime` and `PermissionEngine`;
- CSV/TSV parsing is deterministic and strict: UTF-8, delimiter/header behavior, quoted delimiters, embedded newlines, escaped quotes, CRLF/LF and explicit byte/row/column bounds are tested;
- malformed quotes, ragged rows, empty/duplicate headers and empty tables fail explicitly rather than fabricating structure;
- delimited-text values are lossless text by default, so identifiers such as `00123` are not silently converted to numbers;
- formula-like source cells remain inert text; Lumi never executes formulas, macros, VBA or model-generated spreadsheet code;
- table, column and 2D source-range identities are explicit; `spreadsheet.inspect@1` supports bounded one-based inclusive range selection with a 100,000-cell budget;
- `spreadsheet.profile@1` returns deterministic aggregate column statistics without persisting raw row samples;
- `spreadsheet.query@1` provides whitelisted column selection, filter and stable sort operations; equal sort keys tie-break by original source row order;
- all source reads use broker-registered opaque `UserFileResourceID`; a model-invented path/resource fails before an approval prompt;
- spreadsheet content is lower-authority user data and cannot register tools, grant permissions or change policy;
- sensitive spreadsheet row results are available to the model only in the current run; durable tool history stores redacted structural metadata, and later turns cannot recover the transient cells;
- read and write filesystem boundaries are separate protocols; a read-only broker does not automatically gain write authority;
- `spreadsheet.previewMutation@1` reads/transforms first and stores an immutable process-local plan; write approval never causes a fresh reinterpretation of the source;
- the preview plan binds source resource, destination resource, exact transform, row/column result and an ephemeral plan token;
- `spreadsheet.writeMutation@1` requires `writeUserFile`; requested session grants are downgraded to one exact operation in `PermissionEngine`;
- approval is bound to the exact output resource plus exact code-owned operation details, so plan A cannot authorize plan B even when both target the same output;
- the destination must be a different registered resource from the source;
- Phase 8 writes only to a separate **empty** CSV/TSV output; an existing/non-empty output is rejected and never silently overwritten;
- CSV/TSV export properly quotes fields and prefixes dangerous spreadsheet-formula starters (`=`, `+`, `-`, `@`, tab, CR after leading spaces) with an apostrophe;
- successful writes consume their ephemeral plan token, preventing replay;
- LumiMac exposes `New Table Output…`, selected-source/output identity, bounded table preview, and an approval panel showing affected rows/columns, source/output IDs, overwrite policy and formula-injection defense.

### Phase 7 — long-term user-memory invariants

- user memory has its own `MemoryStore` / `SQLiteMemoryStore`; it is not chat history and is not mixed with document Knowledge;
- every active record has a stable logical key/identity, kind, value, confidence, provenance, timestamps and revision;
- SQLite writes are transactional and memory survives reopen;
- replacement requires the exact current revision; stale writes fail closed and revision history remains explainable;
- hard forget removes active memory and stored revision payloads, and the forgotten value is absent from the next user-turn context;
- model prose cannot mutate persistent memory;
- `memory.remember@1` / `memory.forget@1` require explicit exact-operation permission and never receive session-scoped mutation grants;
- model arguments cannot forge provenance;
- durable tool history redacts private persistent-memory values;
- memory retrieval is deterministic/bounded and memory remains lower-authority contextual data;
- Knowledge and Memory coexist with separate provenance/budgets and Memory cannot fabricate Knowledge citations;
- LumiMac compiles with separate `memory.sqlite3`, inspect/edit/forget controls and exact approval previews.

### Phase 6 — grounded Knowledge invariants

- deterministic lexical retrieval returns ranked chunks with document/source/chunk/page provenance;
- meaningless/no-match queries do not dump documents;
- context is explicitly bounded and prompt-injection-like document text remains lower-authority data;
- Recall@k and MRR fixtures evaluate retrieval quality before a future embedding layer;
- `AgentRuntime` retrieves one immutable context snapshot per user turn and reuses it through permission pauses;
- retrieved source text is ephemeral and is not duplicated into chat history;
- citation labels resolve only against that exact Knowledge snapshot; unknown or hallucinated citations fail closed;
- LumiMac renders validated document/page citation metadata.

### Previously established Core invariants

- user input persists before model/tool execution;
- storage failure enters Safe Mode rather than silently falling back to RAM;
- file reads require explicit exact-resource permission;
- one-time grants are consumed; only capabilities that explicitly support session grants may retain them;
- grants do not cross resource or exact-operation boundaries;
- unknown tools, duplicate registrations and model wire-name collisions fail closed;
- chat/model prose cannot grant permissions;
- approval is bound to the exact pending operation;
- denial is durable and the model may continue safely;
- tool loops stop at a hard step limit;
- tool failure does not erase the original durable user message;
- native tool history preserves provider `tool_call_id` and reconstructs a valid assistant-tool-call → tool-result protocol exchange;
- malformed/unknown/multiple native tool calls fail closed;
- document extraction cannot substitute another opaque source identity;
- Knowledge replacement is transactional and survives reopen.

## macOS platform evidence

Current macOS CI covers **8 tests with zero failures** and a successful LumiMac build:

- selected-file security-scoped bookmark survives catalog reopen and remains readable;
- registering the same selected file reuses a stable opaque resource identity;
- unknown user-file resource IDs fail closed;
- an explicitly registered empty output can be written once and a subsequent require-empty write is rejected without modifying the file;
- PDFKit extraction preserves opaque source identity and one-based page provenance;
- non-PDF resources fail through a structured unsupported-resource path;
- blank/image-only PDFs report an explicit no-extractable-text result;
- selected PDF → bookmark → PDFKit → KnowledgeIngestionEngine → SQLite KnowledgeStore → reopen succeeds end-to-end inside the automated platform boundary.

## Golden Test 001 — durability

A conversation written through `AgentRuntime` must still exist after the SQLite store is closed and reopened.

Automated CI evidence passes. Interactive macOS restart remains the E2E gate.

## Golden Test 002 — protected file action

A native model-requested `file.readText` action must pause before reading, expose exact resource/capability, execute only after explicit approval, persist protocol-complete tool history and let the model continue.

Automated model/runtime and macOS security-scoped-file evidence pass. A live local-model/macOS file-selection run remains the E2E gate.

## Golden Test 003 — durable PDF knowledge ingestion

A user-selected PDF must be extracted only through its trusted registered resource, retain source/page provenance, become bounded deterministic chunks, commit atomically to KnowledgeStore and survive reopen.

Automated Core/macOS evidence passes. OCR remains deliberately separate.

## Golden Test 004 — grounded answer with verified citations

For one query, Lumi must retrieve one bounded immutable evidence snapshot, keep it through tool/permission pauses, treat document text as lower-authority evidence and accept citations only if they resolve against that snapshot.

Automated evidence passes. A live local-model answer against an actually indexed PDF remains the E2E gate.

## Golden Test 005 — explicit durable long-term memory

Persistent user memory may change only through direct user Memory UI action or an explicitly approved typed memory operation. It must survive reopen with provenance/revision metadata, remain bounded/lower-authority in model context, and hard forget must remove it from the next turn.

Automated evidence passes. A real local-model remember → restart → edit → forget flow remains the E2E gate.

## Golden Test 006 — protected spreadsheet transform/export

A user-selected CSV/TSV source must be parsed only through its opaque broker resource. Lumi may inspect/profile/query it only through bounded deterministic typed operations. To export a transform, Lumi must first build an immutable preview plan, pause for source-read permission as needed, then pause **again** for exact destination-write permission. The destination must be separate and empty, persistent file-write authority must be one-operation only, and exported formula-like cells must be neutralized. Raw spreadsheet rows and the ephemeral plan token must not survive into durable chat/tool history or the next user turn.

Automated `SpreadsheetAgentRuntimeTests.testGolden006PreviewApprovalWriteApprovalAndFinalResponse` passes, including both permission pauses, exact write binding, formula-injection defense, final model continuation and next-turn privacy. Core mutation tests additionally verify no overwrite, no source==destination, no cross-plan grant reuse and deterministic transform output. macOS tests verify the real security-scoped destination can be written once but not silently overwritten.

The remaining gate before calling this `E2E_TESTED` is one interactive macOS/local-model run: select a CSV/TSV source → create a new output with `NSSavePanel` → ask Lumi for a transform → inspect the preview/write approval → approve once → open the exported file and verify content/neutralization. No automated test is being overstated as that live E2E result.
