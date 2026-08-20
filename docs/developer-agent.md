# Lumi V4 Developer Agent

M5 adds a deliberately constrained software-development workflow. The Developer Agent is not allowed to rewrite the running Lumi process in place and it is not an unrestricted shell agent.

## Required topology

The developer repository must be a **separate Git checkout/worktree** configured through:

```bash
export LUMI_DEV_REPO_ROOT="$HOME/Projects/Lumi-dev-worktree"
export LUMI_DEV_BASE_BRANCH=main
```

If `LUMI_DEV_REPO_ROOT` points at the source tree from which the current Lumi Core is running, the developer API is disabled. This prevents direct runtime self-modification.

Draft pull-request publishing is optional and requires an explicit fixed GitHub repository plus a token supplied only through the process environment:

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
run fixed allow-listed check profiles
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

Publishing is a second independent approval. Passing tests does not grant publish permission.

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

All proposed paths are resolved against the configured repository root before any approval is requested.

## Test execution

The model does not supply commands. Lumi selects from fixed profiles based on changed paths:

- `python-core-tests` → Python core pytest suite;
- `rag-regression` → deterministic RAG gate;
- `memory-regression` → deterministic memory gate;
- `swift-tests` → native macOS Swift package tests.

These commands execute repository code, so they only run **after** the user approves the proposal that produced those changes.

## Repository invariants

Lumi fails closed when:

- the repository is dirty before planning or application;
- planning does not start on the configured base branch;
- the repository changes between proposal generation and approval;
- a proposal contains duplicate, escaping, missing, or contradictory file operations;
- unexpected worktree paths appear before publish;
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
- Publishing currently targets GitHub only.
- A failed application may leave an isolated local developer branch for manual inspection; it is never pushed automatically.
- CI verifies the workflow against temporary Git repositories and a fake PR publisher. A real local Ollama + real GitHub-token end-to-end session remains a machine-specific acceptance test.
