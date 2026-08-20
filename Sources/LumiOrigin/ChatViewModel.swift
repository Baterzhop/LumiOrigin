#if canImport(SwiftUI)
import Foundation
import SwiftUI
import LumiCore

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isSending = false
    @Published var selectedProfile = "auto"
    @Published var lastIntent: LumiIntent = .chat
    @Published var contextHits: [KnowledgeHit] = []
    @Published var status = "Local-first"
    @Published var runtime: RuntimeMetadata?

    let profiles = ["auto", "chat", "knowledge", "coding", "reflection"]
    private let engine: LumiEngine

    init(engine: LumiEngine = LumiEngine()) {
        self.engine = engine
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        input = ""
        isSending = true
        messages.append(ChatMessage(role: .user, content: text))

        let profileOverride = selectedProfile == "auto" ? nil : selectedProfile

        Task {
            let reply = await engine.respond(to: text, profile: profileOverride)
            messages = await engine.messages()
            lastIntent = reply.intent
            contextHits = reply.context
            runtime = reply.runtime

            if reply.runtime.fallbackUsed {
                status = "Fallback mode"
            } else {
                switch reply.runtime.provider {
                case .ollama:
                    status = "Model ready"
                case .localFallback:
                    status = "Fallback mode"
                case .unknown:
                    status = "Model error"
                }
            }

            isSending = false
        }
    }

    func clear() {
        Task {
            await engine.clearConversation()
            messages = []
            contextHits = []
            lastIntent = .chat
            runtime = nil
            status = "Local-first"
        }
    }
}
#endif
