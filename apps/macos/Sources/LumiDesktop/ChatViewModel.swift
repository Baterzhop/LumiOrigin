import Foundation
import SwiftUI
import LumiClientCore

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatBubble] = []
    @Published var input = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var status = "Checking Lumi Core…"
    @Published private(set) var coreVersion = "—"
    @Published private(set) var modelName = "—"
    @Published private(set) var providerName = "—"
    @Published private(set) var conversationID: String?
    @Published private(set) var generationID: String?
    @Published private(set) var knowledgeStatus = "No documents loaded"
    @Published private(set) var documentCount = 0
    @Published private(set) var isImportingKnowledge = false

    private let api: LumiAPIClient
    private var streamTask: Task<Void, Never>?

    init(api: LumiAPIClient = LumiAPIClient()) {
        self.api = api
    }

    func refreshRuntime() async {
        do {
            let health = try await api.health()
            let runtime = try await api.runtimeStatus()
            coreVersion = health.version
            modelName = runtime.model
            providerName = runtime.provider
            status = health.ok && runtime.ok ? "Core ready" : "Core degraded"
            await refreshKnowledge()
        } catch {
            status = "Core offline"
        }
    }

    func refreshKnowledge() async {
        do {
            let documents = try await api.knowledgeDocuments()
            documentCount = documents.count
            knowledgeStatus = documents.isEmpty ? "No documents loaded" : "\(documents.count) document(s) indexed"
        } catch {
            knowledgeStatus = "Knowledge unavailable"
        }
    }

    func importKnowledge(_ url: URL) {
        guard !isImportingKnowledge else { return }
        isImportingKnowledge = true
        knowledgeStatus = "Importing \(url.lastPathComponent)…"
        Task {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let result = try await api.uploadKnowledge(fileURL: url)
                let dense = result.embeddingError == nil && result.embeddingModel != nil ? "dense ready" : "sparse ready"
                knowledgeStatus = "\(result.title): \(result.chunkCount) chunks, \(dense)"
                await refreshKnowledge()
            } catch {
                knowledgeStatus = "Import failed: \(error.localizedDescription)"
            }
            isImportingKnowledge = false
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        input = ""
        isGenerating = true
        status = "Connecting…"
        generationID = nil
        messages.append(ChatBubble(role: .user, content: text))
        let assistantID = UUID()
        messages.append(ChatBubble(id: assistantID, role: .assistant, content: ""))

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = api.streamChat(message: text, conversationID: conversationID)
                for try await event in stream {
                    consume(event, assistantID: assistantID)
                }
                if isGenerating {
                    isGenerating = false
                    generationID = nil
                    if status == "Generating" || status == "Connecting…" { status = "Stream ended" }
                }
            } catch is CancellationError {
                isGenerating = false
                generationID = nil
                status = "Cancelled"
            } catch {
                isGenerating = false
                generationID = nil
                status = "Connection error"
                if let index = messages.firstIndex(where: { $0.id == assistantID }), messages[index].content.isEmpty {
                    messages[index].content = error.localizedDescription
                    messages[index].finishReason = "error"
                }
            }
        }
    }

    func stop() {
        guard isGenerating else { return }
        status = "Stopping…"
        guard let generationID else {
            streamTask?.cancel()
            return
        }
        Task { try? await api.cancelGeneration(generationID) }
    }

    func newConversation() {
        guard !isGenerating else { return }
        conversationID = nil
        generationID = nil
        messages.removeAll()
        status = "Core ready"
    }

    private func consume(_ event: ChatStreamEvent, assistantID: UUID) {
        conversationID = event.conversationID
        generationID = event.generationID
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        if let citations = event.citations, !citations.isEmpty {
            messages[index].citations = citations
        }

        switch event.type {
        case .started:
            status = messages[index].citations.isEmpty ? "Generating" : "Generating with \(messages[index].citations.count) source(s)"
        case .delta:
            if let delta = event.delta { messages[index].content += delta }
            messages[index].provider = event.provider
            messages[index].model = event.model
            status = event.fallback == true ? "Fallback mode" : "Generating"
        case .completed:
            if messages[index].content.isEmpty, let content = event.content { messages[index].content = content }
            messages[index].provider = event.provider
            messages[index].model = event.model
            messages[index].finishReason = event.finishReason
            isGenerating = false
            generationID = nil
            providerName = event.provider ?? providerName
            modelName = event.model ?? modelName
            status = event.fallback == true ? "Fallback complete" : (event.error == nil ? "Ready" : "Completed with model error")
        case .cancelled:
            if messages[index].content.isEmpty, let content = event.content { messages[index].content = content }
            messages[index].finishReason = "cancelled"
            isGenerating = false
            generationID = nil
            status = "Cancelled"
        case .error:
            if messages[index].content.isEmpty {
                messages[index].content = event.error.map { "Generation failed: \($0)" } ?? "Generation failed."
            }
            messages[index].finishReason = "error"
            isGenerating = false
            generationID = nil
            status = "Generation error"
        }
    }
}
