# Lumi V4 Developer Agent

M5 adds a deliberately constrained software-development workflow. The Developer Agent is not allowed to rewrite the running Lumi process in place and it is not an unrestricted shell agent.

## Required topology

The developer repository must be a **separate Git checkout/worktree** configured through:

```bash
export LUMI_DEV_REPO_ROOT="$HOME/Projects/Lumi-dev-worktree"
export LUMI_DEV_BASE_BRANCH=main
```

If `LUMI_DEV_REPO_ROOT` overlaps the source tree from which the current Lumi Core is running, the developer API is disabled. This prevents direct runtime self-modification.

## Local validation is opt-in

Repository tests execute code from the developer checkout. For that reason Lumi disables local check execution by default.

To allow the fixed validation profiles after you review and approve a proposal:

```bash
export LUMI_DEV_ALLOW_LOCAL_CHECKS=true
```

If a proposal requires checks while this setting is disabled, Lumi records the checks as `skipped`, moves the session to `validation_incomplete`, and **blocks publishing**. This is deliberate fail-closed behavior.

The model never supplies validation commands. Lumi can only select fixed profiles from code:

- `python-core-tests` → Python core pytest suite;
- `rag-regression` → deterministic RAG gate;
- `memory-regression` → deterministic memory gate;
- `swift-tests` → native macOS Swift package tests.

## Optional GitHub draft-PR publishing

Publishing requires an explicit fixed repository plus a token supplied only through the process environment:

```bash
export LUMI_DEV_GITHUB_REPOSITORY="owner/repository"
export LUMI_DEV_GITHUB_TOKEN="..."
```

The token is never stored in SQLite and is never returned by the API.

## Workflow

```text
User goal
  ↓
read-only repository inspection
  ↓
strict JSON proposal
  ↓
render exact file operations + proposed diff
  ↓
USER APPROVAL #1
  ↓
create isolated lumi/dev-* branch
  ↓
apply exact approved UTF-8 create/replace operations
  ↓
run fixed allow-listed check profiles (only if explicitly enabled)
  ↓
all required checks must PASS
  ↓
render actual diff + validation results
  ↓
USER APPROVAL #2
  ↓
commit planned paths only
  ↓
push developer branch
  ↓
create DRAFT pull request
  ↓
STOP — never auto-merge
```

Planning is read-only. No branch, file, commit, push, or pull request is created until the first approval.

Publishing is a second independent approval. Passing tests does not grant publish permission, and incomplete validation cannot be published.

## Allowed file operations

M5 accepts only typed operations:

- `create` a UTF-8 text file;
- `replace` the full content of an existing UTF-8 text file.

The planner cannot request:

- file deletion;
- chmod or ownership changes;
- absolute paths;
- `..` traversal;
- writes under `.git`;
- arbitrary shell commands;
- arbitrary HTTP requests;
- automatic merge.

All proposed paths are resolved against the configured repository root before any approval is requested. Symlink escapes are also rejected after path resolution.

## Repository invariants

Lumi fails closed when:

- the repository is dirty before planning or application;
- planning does not start on the configured base branch;
- the repository changes between proposal generation and approval;
- a proposal contains duplicate, escaping, missing, or contradictory file operations;
- unexpected worktree paths appear before publish;
- required validation fails or is skipped;
- the model falls back or emits malformed proposal JSON;
- GitHub publishing is not configured.

## Auditability

SQLite stores:

- goal;
- proposal;
- proposed/actual diff;
- selected checks;
- validation results;
- developer branch;
- commit SHA;
- draft PR URL;
- state transitions and event payloads.

Credentials are excluded from this state.

## Current M5 alpha limits

- Only complete-file `create`/`replace` edits are supported; patch hunks and rename/delete are intentionally absent.
- Repository inspection is bounded and heuristic; large repositories need a dedicated code index later.
- Fixed check profiles are Lumi-specific and will need a manifest/plugin mechanism for arbitrary projects.
- Local check execution is disabled by default and must be explicitly enabled because tests execute repository code.
- Publishing currently targets GitHub only.
- A failed application may leave an isolated local developer branch for manual inspection; it is never pushed automatically.
- CI verifies the workflow against temporary Git repositories and a fake PR publisher. A real local Ollama + real GitHub-token end-to-end session remains a machine-specific acceptance test.
