# LUMI ONE

This branch is the engineering rebuild of Lumi.

The original Lumi code and concepts remain preserved in Git history and on `main`. The rebuild does not copy the legacy multi-core architecture into production code.

## Current target

Build one reliable macOS application that can:

1. launch without developer intervention;
2. keep conversations across restarts;
3. use a local model through a controlled model interface;
4. access user data only through explicit capabilities;
5. execute tools through one deterministic agent runtime;
6. expose failures instead of silently pretending a subsystem works.

## Repository layout

- `LumiOne/Packages/LumiCore` — portable application core and tests.
- `LumiOne/Apps/LumiMac` — macOS SwiftUI application shell.
- `LumiOne/Docs` — architecture, implementation status, and quality gates.
- legacy root source files — historical Lumi Origin prototype; not referenced by the Lumi One package graph.

## Engineering rules

- One `AgentRuntime`; no Dual Core, AeonCore, MetaLumi, or competing controllers.
- Deterministic code owns permissions, persistence, side effects, and state transitions.
- LLMs may propose actions; they never execute effects directly.
- No feature is `INTEGRATED` until an end-to-end vertical slice passes.
- Persistent-storage failure enters visible Safe Mode. No silent in-memory fallback.
- Self-modification is proposal-only and remains out of the 1.0 scope.

## Build the core

```bash
swift test
```

## Build the macOS app

```bash
cd LumiOne/Apps/LumiMac
swift build
```

The first quality gate is conversation persistence across process restarts. Tool execution, knowledge ingestion, memory consolidation, and the Table Assistant are added only after this gate is stable.
