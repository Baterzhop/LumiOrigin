#if canImport(SwiftUI)
import Foundation
import SwiftUI
import LumiCore

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isSending = false
    @Published var streamingText = ""
    @Published var selectedProfile = "auto"
    @Published var lastIntent: LumiIntent = .chat
    @Published var contextHits: [KnowledgeHit] = []
    @Published var contextBudget: ContextBudgetReport?
    @Published var status = "Local-first"
    @Published var runtime: RuntimeMetadata?
    @Published var lastError: String?

    let profiles = ["auto", "chat", "knowledge", "coding", "reflection"]
    private let engine: LumiEngine
    private var sendTask: Task<Void, Never>?

    init(engine: LumiEngine = LumiEngine.persistentDefault()) {
        self.engine = engine
        restoreHistory()
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        input = ""
        streamingText = ""
        lastError = nil
        isSending = true
        status = "Generating"
        messages.append(ChatMessage(role: .user, content: text))

        let profileOverride = selectedProfile == "auto" ? nil : selectedProfile

        sendTask = Task {
            let stream = await engine.streamRespond(to: text, profile: profileOverride)

            do {
                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .token(let token):
                        streamingText += token

                    case .completed(let reply):
                        messages = await engine.messages()
                        streamingText = ""
                        lastIntent = reply.intent
                        contextHits = reply.context
                        contextBudget = reply.contextBudget
                        runtime = reply.runtime
                        applyRuntimeStatus(reply.runtime)
                        await applyPersistenceStatusIfNeeded()
                    }
                }
            } catch {
                messages = await engine.messages()
                streamingText = ""

                if Task.isCancelled {
                    status = "Stopped"
                } else {
                    status = "Model error"
                    lastError = error.localizedDescription
                }
                await applyPersistenceStatusIfNeeded()
            }

            isSending = false
            sendTask = nil
        }
    }

    func stop() {
        guard isSending else { return }
        sendTask?.cancel()
        status = "Stopping"
    }

    func clear() {
        sendTask?.cancel()
        sendTask = nil

        Task {
            await engine.clearConversation()
            messages = []
            contextHits = []
            contextBudget = nil
            streamingText = ""
            lastIntent = .chat
            runtime = nil
            lastError = nil
            status = "Local-first"
            isSending = false
            await applyPersistenceStatusIfNeeded()
        }
    }

    private func restoreHistory() {
        Task {
            do {
                let restored = try await engine.restoreConversation()
                messages = restored
                if !restored.isEmpty {
                    status = "History restored"
                }
            } catch {
                status = "Storage error"
                lastError = error.localizedDescription
            }
        }
    }

    private func applyPersistenceStatusIfNeeded() async {
        guard let issue = await engine.persistenceIssue() else { return }
        lastError = issue
        status = "Not saved"
    }

    private func applyRuntimeStatus(_ runtime: RuntimeMetadata) {
        if runtime.fallbackUsed {
            status = "Fallback mode"
            return
        }

        switch runtime.provider {
        case .ollama:
            status = "Model ready"
        case .localFallback:
            status = "Fallback mode"
        case .unknown:
            status = "Model error"
        }
    }
}
#endif
