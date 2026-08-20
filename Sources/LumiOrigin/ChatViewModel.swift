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
    @Published var classification = RequestClassification(
        mode: .direct,
        capabilities: [.reasoning],
        confidence: 1,
        risk: .low
    )
    @Published var contextHits: [KnowledgeHit] = []
    @Published var relevantMemories: [MemoryHit] = []
    @Published var storedMemories: [MemoryRecord] = []
    @Published var memoryDraft = ""
    @Published var editingMemoryID: UUID?
    @Published var contextBudget: ContextBudgetReport?
    @Published var citationReport: CitationReport = .empty
    @Published var status = "Local-first"
    @Published var runtime: RuntimeMetadata?
    @Published var lastError: String?

    let profiles = ["auto", "chat", "knowledge", "coding", "reflection"]
    private let engine: LumiEngine
    private var sendTask: Task<Void, Never>?

    init(engine: LumiEngine = LumiEngine.persistentDefault()) {
        self.engine = engine
        restoreHistory()
        refreshMemories()
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        input = ""
        streamingText = ""
        lastError = nil
        citationReport = .empty
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
                        classification = reply.classification
                        contextHits = reply.context
                        relevantMemories = reply.memories
                        contextBudget = reply.contextBudget
                        citationReport = reply.citationReport
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
            relevantMemories = []
            contextBudget = nil
            citationReport = .empty
            streamingText = ""
            lastIntent = .chat
            classification = RequestClassification(
                mode: .direct,
                capabilities: [.reasoning],
                confidence: 1,
                risk: .low
            )
            runtime = nil
            lastError = nil
            status = "Local-first"
            isSending = false
            await applyPersistenceStatusIfNeeded()
        }
    }

    func saveMemoryDraft() {
        let clean = memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        Task {
            do {
                if let editingMemoryID {
                    _ = try await engine.updateMemory(id: editingMemoryID, content: clean)
                } else {
                    _ = try await engine.remember(clean, kind: .semantic, importance: 0.7)
                }
                memoryDraft = ""
                editingMemoryID = nil
                refreshMemories()
            } catch {
                lastError = error.localizedDescription
                status = "Memory error"
            }
        }
    }

    func beginEditingMemory(_ memory: MemoryRecord) {
        editingMemoryID = memory.id
        memoryDraft = memory.content
    }

    func cancelMemoryEdit() {
        editingMemoryID = nil
        memoryDraft = ""
    }

    func forgetMemory(_ memory: MemoryRecord) {
        Task {
            do {
                try await engine.forgetMemory(id: memory.id)
                relevantMemories.removeAll { $0.record.id == memory.id }
                refreshMemories()
            } catch {
                lastError = error.localizedDescription
                status = "Memory error"
            }
        }
    }

    func refreshMemories() {
        Task {
            do {
                storedMemories = try await engine.storedMemories(limit: 50)
            } catch MemoryError.unavailable {
                storedMemories = []
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func restoreHistory() {
        Task {
            do {
                let restored = try await engine.restoreConversation()
                messages = restored
                if !restored.isEmpty { status = "History restored" }
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
        case .ollama: status = "Model ready"
        case .localFallback: status = "Fallback mode"
        case .unknown: status = "Model error"
        }
    }
}
#endif
