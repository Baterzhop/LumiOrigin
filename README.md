# LumiOrigin

> 🧠 An experimental autonomous AI core, written in Swift, designed to simulate self-reflection, intent detection, emotional response, and memory-based reasoning. Powered by modules like AeonCore, Reflector, SelfCoder, and a SwiftUI interface.

---

## 📦 Architecture

- `AeonCore.swift` — main cognitive core, emotional logic, short-term memory
- `IntentEngine.swift` — intent detection and labeling module
- `Reflector.swift` — internal self-assessment and observation
- `SelfCoder.swift` — allows Lumi to save, compare, and rewrite code snippets
- `LumiApp.swift` — command router & integration core
- `LumiInterface.swift` — SwiftUI-based interface to interact with Lumi

---

## 🧠 Features

- Emotional context & reasoning
- Intent recognition
- Self-observation and summarization
- Self-coding memory (can track and compare changes)
- Lightweight interface with SwiftUI

---

## 🚀 How to Run

1. Clone this repo:
```bash
git clone https://github.com/Baterzhop/LumiOrigin.git
cd LumiOrigin
## 🧪 Getting Started with Xcode Project

To launch LumiOrigin as a full macOS SwiftUI app:

1. Add `LumiOriginApp.swift` with `@main` entry point.
2. Open the folder in **Xcode**.
3. Set `LumiOriginApp.swift` as the entry point if needed.
4. Run on simulator or Mac.

Sample content for `LumiOriginApp.swift`:

```swift
import SwiftUI

@main
struct LumiOriginApp: App {
    var body: some Scene {
        WindowGroup {
            LumiInterface()
        }
    }
}
