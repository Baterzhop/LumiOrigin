# Implementation Status

Status vocabulary: `IDEA` → `SPEC` → `CODED` → `UNIT_TESTED` → `INTEGRATED` → `E2E_TESTED` → `RELEASED`.

| Capability | Status | Evidence / next gate |
|---|---|---|
| Split LumiCore / LumiMac layout | INTEGRATED | GitHub CI tests LumiCore independently on Linux and builds + tests macOS platform support separately |
| Single AgentRuntime | INTEGRATED | request, model-turn, native tool-loop, combined Knowledge + Memory context and permission-flow tests pass; macOS UI compiles |
| SQLite conversation persistence | UNIT_TESTED | restart/reopen durability test passes in CI; interactive app restart still pending |
| Visible storage Safe Mode | UNIT_TESTED | bootstrap failure test passes; UI compiles on macOS |
| OpenAI-compatible local model adapter | INTEGRATED | text + native single-tool-call transport + separate lower-authority Knowledge/Memory evidence envelopes are integrated under deterministic HTTP tests; live local-server run pending |
| Conversation UI | INTEGRATED | LumiMac builds successfully on macOS CI; verified citations plus visible Memory inspect/edit/forget and exact memory approval details are wired; interactive app run still pending |
| Tool runtime | INTEGRATED | typed registry/runtime merged; unknown tools and wire-name collisions fail closed; structured results include warnings/metadata and privacy-aware durable-history redaction |
| Permissions / PolicyEngine | INTEGRATED | exact opaque resource scopes, once/session grants, exact-operation detail binding and macOS Allow/Deny UI are wired and tested; persistent memory mutation is forced to per-operation approval |
| Agent tool loop | INTEGRATED | native typed model decisions, explicit permission suspension/resume, denial flow, durable protocol history and hard step limit tested |
| File read tool | INTEGRATED | `file.readText@2` is bounded, UTF-8-only and accepts only broker-registered opaque `resourceID` values; raw model-supplied paths are not an authority boundary |
| Native local-model tool calling | INTEGRATED | OpenAI-compatible `tools` + `tool_calls`, provider call IDs, schema mapping and full protected round-trip tested; live llama.cpp/local-server E2E pending |
| macOS file access boundary | INTEGRATED | `NSOpenPanel → SecurityScopedFileCatalog → opaque resourceID → ToolRuntime → PermissionEngine`; persistent bookmarks and catalog reopen are tested on macOS CI |
| Knowledge ingestion / PDF | INTEGRATED | trusted opaque resource → PDFKit extraction → page provenance → deterministic bounded chunks → transactional SQLite KnowledgeStore; reopen and rollback tests pass |
| Grounded knowledge retrieval / citations | INTEGRATED | deterministic lexical retrieval, Recall@k/MRR evaluation, bounded untrusted evidence context, stable permission-pause reuse and fail-closed citation validation are wired into LumiMac |
| Long-term user memory | INTEGRATED | separate transactional SQLite store, revision/provenance metadata, exact-operation permission-gated `memory.remember` / `memory.forget`, bounded lexical retrieval, combined ephemeral context and visible LumiMac inspect/edit/forget UI; interactive local-model E2E still pending |
| Spreadsheet / Table Assistant | IDEA | next major application capability after the memory foundation is stable |
| TaskEngine | IDEA | after interactive tool execution is stable |
| Voice / Avatar | IDEA | after 1.0 core gates |
| DeveloperAgent / Darwin evals | IDEA | after 1.0 |
| Fleet / Swarm | DEFERRED | not before stable 1.x |

## Automated evidence

Current Linux Core CI covers **77 tests with zero failures**.

### Phase 7 — long-term user-memory invariants

- user memory has its own `MemoryStore` / `SQLiteMemoryStore`; it is not stored as chat history and is not mixed into document Knowledge;
- every active record has a stable logical key and identity plus kind, value, confidence, provenance, creation/update timestamps and a current revision;
- explicit-user-statement provenance, including conversation/message identifiers, survives SQLite reopen;
- SQLite memory writes are transactional and active memory survives store reopen;
- replacing a logical key requires the exact current revision and appends explainable revision history;
- a stale revision cannot overwrite a newer active value;
- hard forget deletes the logical memory and its stored revision payloads;
- a forgotten memory is absent when `AgentRuntime` builds the next user-turn context snapshot;
- model prose such as “I will remember this” cannot mutate persistent memory even while memory tools are registered;
- model-requested persistent changes are typed `memory.remember@1` / `memory.forget@1` operations and pause for explicit permission;
- memory mutation never receives a session-scoped grant: requested session approval is downgraded to one exact operation;
- permission grants are bound to capability + resource + exact code-owned operation details, so approval for one value cannot authorize a changed value on the same memory key;
- approval metadata exposes the exact proposed key/value/kind/confidence/revision, while LumiMac loads the current value for replacement comparison;
- model tool arguments cannot choose or forge memory provenance;
- memory tool protocol history redacts the raw persistent value on both approval and denial paths rather than duplicating private memory payloads into hidden chat history;
- lexical memory retrieval is deterministic and bounded before embeddings/vector search;
- meaningless/no-match memory queries do not dump the full memory database into model context;
- memory context is ephemeral and is not persisted as user/assistant/tool chat content;
- memory text resembling prompt injection remains lower-authority contextual data and cannot grant permissions, change policy or invoke tools;
- Knowledge and Memory can coexist in one immutable per-turn `ModelContextSnapshot` while retaining separate provenance domains and budgets;
- Knowledge citations remain validated only against Knowledge; Memory cannot masquerade as a document citation;
- LumiMac compiles with separate `memory.sqlite3`, memory tool registration, combined context, visible Memory cards, direct edit/hard-forget controls and exact approval previews.

### Phase 6 — grounded Knowledge invariants

- lexical retrieval returns ranked chunks with document ID, opaque source ID, chunk identity and exact page provenance;
- ranking and tie-breaking are deterministic;
- case, punctuation and duplicate query terms normalize consistently;
- meaningless/no-match queries return no document dump;
- grounded context obeys explicit hit and character budgets and never partially truncates a citation into false provenance;
- document text that resembles prompt injection remains explicitly untrusted source data;
- retrieval quality has deterministic Recall@k and MRR evaluation fixtures before any embedding layer is introduced;
- `AgentRuntime` retrieves context once per user turn and reuses the exact immutable snapshot across permission/tool pauses;
- retrieved source text is ephemeral and is not persisted as user/assistant/tool chat history;
- the OpenAI-compatible payload keeps retrieved source text out of system authority and encloses it as lower-authority evidence;
- citation markers are resolved only against the exact grounded snapshot for that run;
- duplicate citation markers resolve once in first-use order;
- unknown citation labels such as `[K99]` fail closed;
- a citation marker with no grounded context fails closed;
- an assistant response containing a hallucinated citation is rejected before durable assistant-message persistence;
- successful grounded responses return structured validated citation metadata for the UI.

### Previously established Core invariants

- user input persists before model/tool execution;
- storage failure enters Safe Mode rather than silent RAM fallback;
- file reads require explicit exact-resource permission;
- one-time grants are consumed and ordinary session grants remain active;
- a grant for resource A cannot authorize resource B;
- unknown tools fail closed;
- duplicate tool registrations and model wire-name collisions fail closed;
- chat/model prose cannot create or imply a permission grant;
- file content does not reach the model before explicit approval;
- approval is bound to the exact pending operation ID;
- denial is persisted and the model can continue;
- tool loops stop at a hard step limit;
- tool failure does not erase the original durable user message;
- native tool calls preserve the provider `tool_call_id`;
- malformed/unknown/multiple native tool calls fail closed;
- durable tool history reconstructs a valid `assistant tool_call → tool result` exchange;
- a model-invented/unregistered user-file resource fails before Lumi can show an approval prompt;
- document extraction cannot substitute a different opaque source identity;
- chunking is deterministic, bounded and preserves page provenance;
- blank/image-only extracted text produces no visible knowledge document;
- re-ingestion preserves document identity/creation time and replaces old chunks instead of duplicating them;
- knowledge survives SQLite store reopen;
- extraction failure leaves existing knowledge untouched;
- a mid-transaction chunk failure rolls the entire knowledge replacement back.

macOS platform CI covers **7 tests with zero failures** and a successful LumiMac build. In addition to compiling the Phase 7 Memory wiring/UI, the platform tests verify:

- a selected file survives catalog reopen and remains readable through its persisted bookmark;
- registering the same selected file reuses its stable opaque resource identity;
- unknown resource IDs fail closed on the macOS broker as well as in Core;
- PDFKit extraction preserves opaque source identity and one-based page provenance;
- non-PDF resources fail through a structured unsupported-resource path;
- blank/image-only PDFs report an explicit no-extractable-text result;
- selected PDF → trusted bookmark → PDFKit → KnowledgeIngestionEngine → SQLite KnowledgeStore → reopen succeeds end-to-end inside the automated platform boundary.

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

## Golden Test 003 — durable PDF knowledge ingestion

A user-selected PDF must be extracted only through its trusted registered resource, retain source/page provenance, become bounded deterministic chunks, commit atomically to the dedicated KnowledgeStore, and survive store reopen.

Automated Core and macOS integration evidence passes. OCR and semantic/vector retrieval remain deliberately separate phases.

## Golden Test 004 — grounded answer with verified citations

For one user query, Lumi must retrieve a bounded evidence snapshot exactly once, keep that snapshot immutable through any tool/permission pause, send the document text only as explicitly untrusted evidence, and accept citation markers only if they resolve against that exact snapshot.

Automated Core evidence passes for retrieval determinism, context budgeting, prompt-injection-like source text, permission-pause reuse, non-persistence of retrieved context, structured citation resolution and rejection of hallucinated citation labels. LumiMac wires the lexical retriever to the durable `SQLiteKnowledgeStore` and renders the validated document/page citation metadata.

The remaining gate before calling this `E2E_TESTED` is an interactive macOS run against the chosen local model using an actually indexed PDF and visibly correct cited pages.

## Golden Test 005 — explicit durable long-term memory

Persistent user memory may change only through a direct user Memory UI action or an explicitly approved typed memory tool operation. A memory must survive reopen with provenance and revision metadata, enter model reasoning only through a bounded lower-authority context, and never gain permission/policy authority. Approval for one exact mutation must not authorize a changed value on the same key. Hard forget must remove the active memory/revision payloads and the forgotten value must be absent from the next user-turn context.

Automated Core evidence passes for create/reopen, provenance persistence, revision history and stale-write rejection, permission pause, forced one-operation grants, exact-operation binding, prose-only non-mutation, durable-history redaction, bounded/adversarial retrieval, combined Knowledge + Memory context and next-turn forget behavior. LumiMac builds with the separate Memory store, inspect/edit/forget UI and exact current/proposed-value approval surface.

The remaining gate before calling this `E2E_TESTED` is one real interactive macOS/local-model flow: ask Lumi to remember a fact → verify the exact approval preview → approve → confirm the memory appears and survives app restart → edit it → forget it → ask a new related question and verify the forgotten memory is no longer available.