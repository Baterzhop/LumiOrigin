# LumiOrigin V3

LumiOrigin is a small, local-first AI application written in Swift. V3 replaces the original collection of global singletons with an explicit, testable architecture.

## Design principles

- **No simulated sentience claims.** Reflection is a journal of inputs, intents, and response previews.
- **Local-first.** Lumi talks to a local Ollama-compatible endpoint by default and degrades to a deterministic fallback when the model is offline.
- **Explicit state.** Conversation memory, knowledge retrieval, prompt profiles, and reflection history are separate components.
- **Bounded memory.** The app does not silently accumulate unlimited conversation state.
- **Testable core.** `LumiCore` has no SwiftUI dependency and can be tested on macOS or Linux.
- **Replaceable providers.** The model client and knowledge layer are behind small interfaces/components, so remote APIs or a true dense retriever can be added without rewriting the UI.

## Architecture

```text
SwiftUI
  ↓
ChatViewModel
  ↓
LumiEngine
  ├─ IntentRouter
  ├─ PromptRegistry
  ├─ MemoryStore
  ├─ KnowledgeIndex (local BM25 + overlap hybrid)
  ├─ ReflectionJournal
  └─ LLMClient
       ├─ OllamaClient
       └─ LocalFallbackClient
```

## Requirements

- macOS 13+
- Swift 5.9+
- Optional: Ollama or another Ollama-compatible chat endpoint

Default model settings:

```bash
export LUMI_OLLAMA_URL=http://127.0.0.1:11434/api/chat
export LUMI_OLLAMA_MODEL=llama3.2
```

## Run

```bash
swift run LumiOrigin
```

Open the package in Xcode to run the native SwiftUI app.

## Test

```bash
swift test
```

CI runs the core tests on both Ubuntu and macOS.

## Project layout

```text
Sources/
  LumiCore/
    IntentRouter.swift
    KnowledgeIndex.swift
    LLMClient.swift
    LumiEngine.swift
    MemoryStore.swift
    Models.swift
    PromptRegistry.swift
    ReflectionJournal.swift
    Resources/prompts.json
  LumiOrigin/
    ChatViewModel.swift
    ContentView.swift
    LumiOriginMain.swift
Tests/
  LumiCoreTests/
.github/workflows/ci.yml
```

## What changed from the original prototype

The original prototype used global singleton modules such as `Reflector` and `SelfCoder` and referenced missing types. V3 keeps the useful ideas—intent routing, memory, reflection, local AI—but turns them into explicit components with dependency injection and tests. Autonomous self-modification is deliberately not part of the runtime; code changes belong in normal version control and CI.
