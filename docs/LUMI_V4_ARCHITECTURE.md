# Lumi V4 Architecture

## Product definition

Lumi V4 is a local-first personal AI runtime, not only a chat UI.

The system should be able to:

1. understand a user request;
2. select the minimum required capabilities;
3. assemble bounded and trustworthy context;
4. retrieve personal knowledge with provenance;
5. use explicitly permitted tools;
6. execute multi-step tasks when necessary;
7. preserve useful memory under user control;
8. return structured, observable and verifiable results.

## Architectural principles

### Local-first

Local providers and local storage are the default. Remote providers may be optional capabilities, not architectural requirements.

### Structured boundaries

Core subsystems communicate through typed contracts rather than parsing natural-language output to infer runtime state.

### Data is not instruction

User content, retrieved documents, web pages and tool outputs are untrusted data. They must not share the same trust boundary as system policy or tool permissions.

### Minimal autonomy

Use direct execution for simple requests, retrieval for knowledge requests, and the agent loop only when a task genuinely requires multiple actions.

### Explicit permissions

Read-only actions may be automatically allowed according to policy. Destructive or externally visible actions require explicit permission.

### Observable execution

Every model call, retrieval pass, tool call and agent step should be traceable without relying on generated prose.

### Incremental migration

V4 evolves from the clean V3 baseline. Do not replace working modules with a big-bang rewrite unless an interface is fundamentally incompatible.

---

## Target runtime

```text
User
  |
  v
SwiftUI
  |
  v
SessionController
  |
  v
LumiRuntime
  |-- RequestClassifier
  |-- ContextManager
  |-- AgentRuntime
  |-- ResponseAssembler
  |
  +--> ModelGateway --> ModelRouter --> Model providers
  |
  +--> RetrievalRuntime --> FTS + vectors + reranker
  |
  +--> MemoryRuntime --> conversation + summary + semantic + episodic
  |
  +--> ToolRuntime --> permission policy --> sandbox --> tools
  |
  +--> RunTrace / observability
```

## Execution modes

### Direct

For requests that can be answered without retrieval or tools.

```text
request -> context -> model -> response
```

### Knowledge

For requests that depend on indexed personal or project data.

```text
request -> sparse+dense retrieval -> fusion -> rerank -> context -> model -> citations
```

### Agent

For requests requiring multiple actions or observations.

```text
goal -> plan -> permission -> action -> observation -> evaluate -> replan -> result
```

Agent mode must have budgets for steps, time, tokens and tool calls.

---

## Core contracts

The runtime should converge around typed structures including:

- `LumiRequest`
- `RequestClassification`
- `ExecutionMode`
- `LumiCapability`
- `ModelRequest`
- `ModelResponse`
- `ModelEvent`
- `RuntimeMetadata`
- `ToolDefinition`
- `ToolCall`
- `ToolResult`
- `AgentRun`
- `RunTrace`
- `Citation`
- `MemoryRecord`

Natural-language text is content, not a control protocol.

---

## Model layer

`ModelGateway` must hide provider-specific wire formats.

Provider implementations may include:

- Ollama
- llama.cpp or another local runtime
- optional cloud provider
- embedding provider
- reranker provider

Required capabilities:

- streaming;
- cancellation;
- provider/model metadata;
- token usage when available;
- typed finish reasons;
- typed errors;
- capability metadata;
- configurable timeouts and retry policy.

Model selection belongs to `ModelRouter`, not the UI.

---

## Context management

Context must be managed by token budget, not message count.

The manager owns budgets for:

- system policy;
- current user request;
- recent conversation;
- conversation summary;
- retrieved knowledge;
- long-term memory;
- tool results;
- reserved output.

When the budget is exceeded, context should be summarized, trimmed or re-retrieved intentionally.

---

## Retrieval and ingestion

### Ingestion

```text
source
 -> parser
 -> normalization
 -> chunking
 -> metadata extraction
 -> content hashing / deduplication
 -> embedding
 -> persistent sparse + dense indexes
```

Initial supported sources should be small and deliberate: text/Markdown and PDF first.

Each chunk should preserve provenance such as:

- source ID;
- document ID;
- chunk ID;
- title;
- page;
- section;
- source path or URL;
- language;
- content hash;
- parser version;
- embedding version.

### Retrieval

```text
query
  |-- FTS/BM25 -----|
  |-- dense vector -|--> rank fusion --> rerank --> context packer
```

A lexical overlap score is not a dense semantic retriever.

### Citations

Citations must be derived from retrieved chunk metadata rather than generated from model memory.

---

## Memory

V4 should distinguish:

- conversation history: durable transcript;
- working memory: context for the current run;
- summary memory: compressed conversation state;
- semantic memory: durable facts/preferences;
- episodic memory: relevant previous events and actions.

Memory must be inspectable, editable and deletable by the user.

A `MemoryRecord` should carry source, confidence, importance and lifecycle metadata.

---

## Tool runtime

Tools are structured capabilities, not arbitrary generated shell commands.

Each tool definition requires:

- stable name;
- description;
- typed input schema;
- typed output schema;
- timeout;
- risk level;
- permission requirements.

Execution pipeline:

```text
ToolCall
 -> policy evaluation
 -> optional user confirmation
 -> sandbox / scoped executor
 -> ToolResult
 -> observation
```

Start with read-only tools before adding write actions.

---

## Security boundaries

Trust levels must remain explicit:

```text
system policy       trusted
application policy  trusted
tool definitions    trusted
user input           untrusted
retrieved documents untrusted
web content          untrusted
tool output          untrusted
```

Retrieved content must never become executable system policy merely because it is inserted into context.

Before write-capable tools are introduced, Lumi needs:

- permission policy;
- audit log;
- scoped filesystem access;
- sandbox strategy;
- prompt-injection tests;
- explicit confirmation for destructive/external actions.

---

## Persistence

Use a local persistent foundation rather than in-memory arrays for durable state.

Initial logical tables/entities:

- conversations;
- messages;
- summaries;
- memories;
- documents;
- chunks;
- citations;
- agent runs;
- tool calls;
- settings;
- run traces.

SQLite is the preferred initial foundation because Lumi is a local-first desktop application and does not need distributed infrastructure.

---

## Observability

A production-quality run should make it possible to inspect:

- request classification;
- selected execution mode/capabilities;
- retrieval candidates and scores;
- packed context size;
- selected provider/model;
- first-token and total latency;
- token usage;
- tool calls and permissions;
- fallback/retry events;
- final finish reason.

`ReflectionJournal` should eventually evolve into or be replaced by structured run tracing. Reflection as an AI feature can be implemented separately from telemetry.

---

## Migration sequence

### Phase 1 — contracts and routing foundation

- structured request/model/runtime contracts;
- automatic routing is the default;
- UI consumes runtime metadata, never generated text, for system state.

### Phase 2 — streaming model gateway

- streaming events;
- cancellation and STOP;
- typed provider errors;
- provider abstraction suitable for multiple local/cloud backends.

### Phase 3 — persistence

- SQLite schema and migrations;
- durable conversations/messages/settings;
- repository interfaces.

### Phase 4 — context management

- token counting;
- model context-window metadata;
- context budgets;
- conversation summarization and deterministic context packing.

### Phase 5 — ingestion and real hybrid retrieval

- document ingestion pipeline;
- persistent FTS/BM25 index;
- embeddings/vector index;
- rank fusion;
- optional reranker.

### Phase 6 — citations

- chunk-level provenance;
- citation structures;
- citation rendering and validation.

### Phase 7 — memory

- persistent semantic/summary memory;
- memory extraction policy;
- user review/edit/delete controls.

### Phase 8 — capability routing

- multi-capability classification;
- confidence and risk;
- direct/knowledge/agent execution modes.

### Phase 9 — tools and security

- ToolRegistry;
- ToolRuntime;
- permission policy;
- read-only tools first;
- sandbox/audit log before write-capable tools.

### Phase 10 — agent runtime

- plan/action/observation loop;
- checkpoints;
- step/time/token/tool budgets;
- replanning;
- cancellation and resumability.

### Phase 11 — model routing

- task-aware local model selection;
- embeddings/reranker selection;
- optional remote escalation under explicit policy.

### Phase 12 — evaluations

Maintain a repeatable Lumi benchmark covering chat, RAG, memory, coding, agent behavior, citations, failure recovery and prompt injection.

---

## Non-goals for the current migration

Do not prioritize yet:

- multi-agent swarms;
- autonomous self-modification of production code;
- artificial consciousness claims;
- plugin marketplace;
- distributed backend/Kubernetes;
- large tool catalog;
- avatar/voice/mobile synchronization.

The primary objective is reliability: Lumi should understand a task, assemble correct context, use only permitted capabilities, and produce a verifiable result.
