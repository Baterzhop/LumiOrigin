# ADR 0001: Start V4 as a modular monolith

Status: Accepted

## Context

Earlier Lumi concepts mixed UI, memory, reflection, model calls, and self-modification ideas. A microservice split would add deployment, networking, tracing, and consistency problems before the core domain is stable.

## Decision

Use one Python `lumi_core` service with strict internal module boundaries. Keep the macOS application as a separate client. SQLite is the initial canonical store.

## Consequences

- Local development remains simple.
- Transactions and migrations stay centralized.
- Modules can later be extracted behind stable interfaces if profiling or deployment requirements justify it.
- The architecture avoids premature Celery/Redis/service sprawl.
