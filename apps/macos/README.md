# Lumi macOS client

Milestone M1 turns this directory into the native SwiftUI client for Lumi Core.

The client owns presentation and transport concerns only:

- chat presentation and token streaming
- generation cancellation
- runtime/model status
- conversation identifiers
- future file picker, source inspection, approvals, and settings

The client does **not** own prompt routing, RAG ranking, model-provider fallback, memory policy, or tool execution policy.

Build after the M1 Swift package files land with:

```bash
cd apps/macos
swift build
```

Run Lumi Core separately on `http://127.0.0.1:8790`.
