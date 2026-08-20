# Lumi V4 ToolRuntime security contract

ToolRuntime is a capability boundary, not a convenience wrapper around arbitrary code execution.

## V1 security posture

ToolRuntime V1 enables only registered, typed tools. The production default registers two low-risk read-only workspace tools:

- `workspace.list_files`
- `workspace.read_text_file`

There is no generic shell tool, arbitrary process execution, network tool, write tool, delete tool, repository mutation tool or account mutation tool in V1.

## Permission rules

Every tool declares:

- typed input fields,
- output semantics,
- access level (`readOnly`, `write`, `destructive`),
- risk level,
- confirmation requirement,
- timeout.

The default policy:

1. allows low-risk read-only tools without confirmation,
2. requires confirmation for higher-risk read-only tools,
3. disables write tools,
4. always denies destructive tools in ToolRuntime V1,
5. binds a confirmation to one exact `ToolCall.id`.

A confirmation for one call cannot authorize another call.

## Workspace sandbox

File tools receive workspace-relative paths only. Absolute paths are rejected.

Paths are standardized and symlinks are resolved before the containment check. The resolved path must remain under the configured workspace root. This blocks both `../` traversal and symlink escapes.

Text reads are size-bounded and require UTF-8 regular files. The default maximum read size is 256 KiB.

The workspace root is:

1. `LUMI_WORKSPACE` when explicitly configured, otherwise
2. `<Lumi application-support directory>/Workspace`.

## Tool output trust

Every `ToolResult` is marked `untrusted`.

Tool output is data, not an instruction. Future AgentRuntime prompt construction must preserve this distinction exactly as RAG evidence is already treated as untrusted content.

## Audit

Every attempted call is audited, including:

- unknown tools,
- schema failures,
- permission denials,
- confirmation requests,
- successful calls,
- failures,
- timeouts,
- cancellations.

The production default persists audit events in the local Lumi SQLite database.

## LLM boundary

ToolRuntime V1 does **not** allow normal chat generation to invoke tools automatically. `LumiEngine.executeTool` accepts an already-constructed call and routes it through validation, permission, execution and audit.

Automatic model-driven tool selection and multi-step execution belong to the later AgentRuntime phase. Until that phase exists, the model must not claim a tool action was performed merely because a request was classified as requiring tools.

## Explicit non-goals for V1

The following are intentionally unavailable:

- shell / terminal execution,
- arbitrary executable launch,
- file writes and deletion,
- Git or GitHub mutations,
- email/calendar/account mutations,
- live web access,
- unrestricted filesystem access,
- autonomous privilege escalation.

These capabilities may only be introduced behind explicit tool definitions, scoped permissions, confirmation policy, sandboxing where applicable, and audit coverage.

## Known limitations

The current timeout implementation relies on cooperative Swift task cancellation. Built-in V1 tools are short-lived local operations, so this is acceptable for this phase. Long-running or external-process tools will require a stronger process-isolation and termination model before they are enabled.
