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

    @Published private(set) var memories: [MemoryRecordDTO] = []
    @Published private(set) var memoryStatus = "No durable memories"
    @Published private(set) var memorySemanticEnabled = false
    @Published private(set) var isUpdatingMemory = false

    @Published var agentGoal = ""
    @Published private(set) var agentTask: AgentTaskDTO?
    @Published private(set) var agentStatus = "No agent task"
    @Published private(set) var isRunningAgent = false
    @Published private(set) var toolCount = 0
    @Published private(set) var toolWorkspace = "—"

    private let api: LumiAPIClient
    private var streamTask: Task<Void, Never>?

    var pendingToolCall: ToolCallDTO? {
        agentTask?.toolCalls.first(where: { $0.status == "awaiting_approval" })
    }

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
            toolCount = runtime.tools?.count ?? 0
            toolWorkspace = runtime.tools?.workspace ?? "—"
            memorySemanticEnabled = runtime.memory?.semanticEnabled ?? false
            status = health.ok && runtime.ok ? "Core ready" : "Core degraded"
            await refreshKnowledge()
            await refreshMemories()
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

    func refreshMemories() async {
        do {
            memories = try await api.memories()
            memoryStatus = memories.isEmpty
                ? "No durable memories"
                : "\(memories.count) approved memory item(s)"
        } catch {
            memoryStatus = "Memory unavailable"
        }
    }

    func createMemory(content: String, title: String?, kind: String) {
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isUpdatingMemory else { return }
        isUpdatingMemory = true
        memoryStatus = "Saving approved memory…"
        Task {
            do {
                _ = try await api.createMemory(content: clean, kind: kind, title: title)
                await refreshMemories()
            } catch {
                memoryStatus = "Memory save failed: \(error.localizedDescription)"
            }
            isUpdatingMemory = false
        }
    }

    func updateMemory(_ memory: MemoryRecordDTO, content: String, title: String?, kind: String) {
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isUpdatingMemory else { return }
        isUpdatingMemory = true
        memoryStatus = "Updating memory…"
        Task {
            do {
                _ = try await api.updateMemory(memory.id, content: clean, kind: kind, title: title)
                await refreshMemories()
            } catch {
                memoryStatus = "Memory update failed: \(error.localizedDescription)"
            }
            isUpdatingMemory = false
        }
    }

    func deleteMemory(_ memoryID: String) {
        guard !isUpdatingMemory else { return }
        isUpdatingMemory = true
        memoryStatus = "Deleting memory…"
        Task {
            do {
                try await api.deleteMemory(memoryID)
                await refreshMemories()
            } catch {
                memoryStatus = "Memory deletion failed: \(error.localizedDescription)"
            }
            isUpdatingMemory = false
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

    func runAgentTask() {
        let goal = agentGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !isRunningAgent else { return }
        isRunningAgent = true
        agentStatus = "Planning…"
        agentTask = nil
        Task {
            do {
                let task = try await api.createTask(goal: goal, conversationID: conversationID)
                agentTask = task
                agentStatus = describe(task)
                if task.status == "completed" { agentGoal = "" }
            } catch {
                agentStatus = "Agent error: \(error.localizedDescription)"
            }
            isRunningAgent = false
        }
    }

    func approvePendingTool() {
        guard let call = pendingToolCall, !isRunningAgent else { return }
        isRunningAgent = true
        agentStatus = "Executing approved tool…"
        Task {
            do {
                let task = try await api.approveToolCall(call.id)
                agentTask = task
                agentStatus = describe(task)
                if task.status == "completed" { agentGoal = "" }
            } catch {
                agentStatus = "Approval failed: \(error.localizedDescription)"
            }
            isRunningAgent = false
        }
    }

    func denyPendingTool() {
        guard let call = pendingToolCall, !isRunningAgent else { return }
        isRunningAgent = true
        agentStatus = "Denying tool…"
        Task {
            do {
                let task = try await api.denyToolCall(call.id)
                agentTask = task
                agentStatus = describe(task)
            } catch {
                agentStatus = "Denial failed: \(error.localizedDescription)"
            }
            isRunningAgent = false
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

    private func describe(_ task: AgentTaskDTO) -> String {
        switch task.status {
        case "awaiting_approval":
            if let call = task.toolCalls.first(where: { $0.status == "awaiting_approval" }) {
                return "Approval required: \(call.toolName) [\(call.risk)]"
            }
            return "Approval required"
        case "completed":
            return task.resultText.map { "Completed: \($0)" } ?? "Task completed"
        case "budget_exceeded":
            return "Budget exceeded: \(task.error ?? "limit reached")"
        case "failed":
            return "Task failed: \(task.error ?? "unknown error")"
        case "denied":
            return "Task denied: \(task.error ?? "policy")"
        default:
            return task.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func consume(_ event: ChatStreamEvent, assistantID: UUID) {
        conversationID = event.conversationID
        generationID = event.generationID
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        if let citations = event.citations, !citations.isEmpty {
            messages[index].citations = citations
        }
        if let memories = event.memories, !memories.isEmpty {
            messages[index].memories = memories
        }

        switch event.type {
        case .started:
            let evidence = messages[index].citations.count
            let recalled = messages[index].memories.count
            if evidence > 0 || recalled > 0 {
                status = "Generating · \(evidence) source(s) · \(recalled) memory item(s)"
            } else {
                status = "Generating"
            }
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
