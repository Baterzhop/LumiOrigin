#if canImport(SwiftUI)
import Foundation
import SwiftUI
import LumiCore

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isSending = false
    @Published var selectedProfile = "chat"
    @Published var lastIntent: LumiIntent = .chat
    @Published var contextHits: [KnowledgeHit] = []
    @Published var status = "Local-first"

    let profiles = ["chat", "knowledge", "coding", "reflection"]
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

        Task {
            let reply = await engine.respond(to: text, profile: selectedProfile)
            messages = await engine.messages()
            lastIntent = reply.intent
            contextHits = reply.context
            status = reply.message.content.hasPrefix("Local model is unavailable") ? "Fallback mode" : "Model ready"
            isSending = false
        }
    }

    func clear() {
        Task {
            await engine.clearConversation()
            messages = []
            contextHits = []
            lastIntent = .chat
            status = "Local-first"
        }
    }
}
#endif
