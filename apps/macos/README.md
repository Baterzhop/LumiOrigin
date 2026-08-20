# Lumi macOS client

The native client remains SwiftUI, but V4 moves AI orchestration out of the UI process.

The client will own:

- chat/task presentation
- streaming event rendering
- file picker and user-approved imports
- approval dialogs for risky tool calls
- Keychain-backed credentials/settings
- memory/source inspection UI
- runtime health/status

The client will **not** own prompt routing, RAG ranking, model-provider fallback logic, or tool execution policy.

Implementation begins in Milestone M1 after the core HTTP/event contracts are stable.
