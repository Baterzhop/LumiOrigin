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

    @Published var agentGoal = ""
    @Published var activeAgentRun: AgentRun?
    @Published var recentAgentRuns: [AgentRun] = []
    @Published var isAgentRunning = false
    @Published var agentError: String?
    @Published var agentActivity: String?

    let profiles = ["auto", "chat", "knowledge", "coding", "reflection"]
    private let engine: LumiEngine
    private var sendTask: Task<Void, Never>?
    private var agentTask: Task<Void, Never>?

    init(engine: LumiEngine = LumiEngine.persistentDefault()) {
        self.engine = engine
        restoreHistory()
        refreshMemories()
        refreshAgentRuns()
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isAgentRunning else { return }

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

    func startAgent() {
        let goal = agentGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !isAgentRunning, !isSending else { return }

        agentError = nil
        agentActivity = "Starting agent"
        isAgentRunning = true
        status = "Agent running"
        agentTask?.cancel()

        agentTask = Task {
            do {
                guard let agentRuntime = await engine.agentRuntime else {
                    throw AgentRuntimeError.invalidState("AgentRuntime is not configured for this LumiEngine.")
                }
                let events = await agentRuntime.events()
                let run = try await executeAgentOperation(observing: events) {
                    try await self.engine.startAgent(goal: goal)
                }
                applyAgentRun(run)
                if run.state == .completed {
                    agentGoal = ""
                }
                refreshAgentRuns()
            } catch is CancellationError {
                agentError = "Agent operation was cancelled."
                status = "Agent cancelled"
                agentActivity = nil
                refreshAgentRuns()
            } catch {
                agentError = error.localizedDescription
                status = "Agent error"
                agentActivity = nil
            }

            isAgentRunning = false
            agentTask = nil
        }
    }

    func approvePendingAgentCall() {
        resumePendingAgentCall(approved: true)
    }

    func rejectPendingAgentCall() {
        resumePendingAgentCall(approved: false)
    }

    func cancelActiveAgent() {
        if isAgentRunning {
            agentTask?.cancel()
            status = "Agent stopping"
            agentActivity = "Cancelling active run"
            return
        }

        guard let run = activeAgentRun else { return }
        agentTask = Task {
            do {
                let cancelled = try await engine.cancelAgent(runID: run.id)
                applyAgentRun(cancelled)
                agentActivity = nil
                refreshAgentRuns()
            } catch {
                agentError = error.localizedDescription
                status = "Agent error"
            }
            isAgentRunning = false
            agentTask = nil
        }
    }

    func selectAgentRun(_ run: AgentRun) {
        activeAgentRun = run
        agentError = run.error
        agentActivity = nil
        applyAgentStatus(run.state)
    }

    func refreshAgentRuns() {
        Task {
            do {
                recentAgentRuns = try await engine.recentAgentRuns(limit: 20)
                if activeAgentRun == nil,
                   let resumable = recentAgentRuns.first(where: { $0.state == .waitingForConfirmation }) {
                    activeAgentRun = resumable
                    applyAgentStatus(resumable.state)
                }
            } catch let error as AgentRuntimeError {
                if case .invalidState = error {
                    recentAgentRuns = []
                    return
                }
                agentError = error.localizedDescription
            } catch {
                agentError = error.localizedDescription
            }
        }
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

    private func resumePendingAgentCall(approved: Bool) {
        guard !isAgentRunning,
              let run = activeAgentRun,
              run.state == .waitingForConfirmation,
              let pending = run.pendingCall else { return }

        agentError = nil
        agentActivity = approved ? "Applying approved tool call" : "Recording rejected tool call"
        isAgentRunning = true
        status = approved ? "Agent resuming" : "Agent observing rejection"
        agentTask?.cancel()

        agentTask = Task {
            do {
                guard let agentRuntime = await engine.agentRuntime else {
                    throw AgentRuntimeError.invalidState("AgentRuntime is not configured for this LumiEngine.")
                }
                let events = await agentRuntime.events()
                let resumed = try await executeAgentOperation(observing: events) {
                    try await self.engine.resumeAgent(
                        runID: run.id,
                        confirmation: ToolConfirmation(callID: pending.id, approved: approved)
                    )
                }
                applyAgentRun(resumed)
                refreshAgentRuns()
            } catch is CancellationError {
                agentError = "Agent operation was cancelled."
                status = "Agent cancelled"
                agentActivity = nil
                refreshAgentRuns()
            } catch {
                agentError = error.localizedDescription
                status = "Agent error"
                agentActivity = nil
            }

            isAgentRunning = false
            agentTask = nil
        }
    }

    private func executeAgentOperation(
        observing events: AsyncStream<AgentEvent>,
        operation: @escaping @Sendable () async throws -> AgentRun
    ) async throws -> AgentRun {
        var operationResult: AgentRun?

        try await withThrowingTaskGroup(of: AgentOperationSignal.self) { group in
            group.addTask {
                .operation(try await operation())
            }

            group.addTask { [weak self] in
                for await event in events {
                    try Task.checkCancellation()
                    await self?.applyAgentEvent(event)

                    switch event {
                    case .terminal, .confirmationRequired, .runtimeFailure:
                        return .observerFinished
                    case .runUpdated, .toolStarted, .toolFinished:
                        continue
                    }
                }
                return .observerFinished
            }

            while let signal = try await group.next() {
                switch signal {
                case .operation(let run):
                    operationResult = run
                    group.cancelAll()
                    return
                case .observerFinished:
                    continue
                }
            }
        }

        guard let operationResult else {
            throw AgentRuntimeError.invalidState("Agent operation finished without a run result.")
        }
        return operationResult
    }

    private func applyAgentEvent(_ event: AgentEvent) {
        switch event {
        case .runUpdated(let run):
            applyAgentRun(run)
            agentActivity = activity(for: run.state)

        case .toolStarted(_, let call):
            agentActivity = "Running \(call.toolName)"
            status = "Agent executing tool"

        case .toolFinished(_, let result):
            agentActivity = "\(result.toolName): \(result.status.rawValue)"
            status = "Agent observing"

        case .confirmationRequired(_, let call):
            agentActivity = "Waiting for approval: \(call.toolName)"
            status = "Agent needs approval"

        case .terminal(let run):
            applyAgentRun(run)
            agentActivity = nil

        case .runtimeFailure(_, let message):
            agentError = message
            agentActivity = nil
            status = "Agent error"
        }
    }

    private func applyAgentRun(_ run: AgentRun) {
        activeAgentRun = run
        agentError = run.error
        applyAgentStatus(run.state)
    }

    private func applyAgentStatus(_ state: AgentRunState) {
        switch state {
        case .created, .planning, .executing, .observing, .replanning:
            status = "Agent running"
        case .waitingForConfirmation:
            status = "Agent needs approval"
        case .completed:
            status = "Agent completed"
        case .failed:
            status = "Agent failed"
        case .cancelled:
            status = "Agent cancelled"
        case .budgetExceeded:
            status = "Agent budget exceeded"
        }
    }

    private func activity(for state: AgentRunState) -> String? {
        switch state {
        case .created: return "Creating run"
        case .planning: return "Planning"
        case .executing: return "Preparing tool execution"
        case .waitingForConfirmation: return "Waiting for approval"
        case .observing: return "Observing tool result"
        case .replanning: return "Replanning"
        case .completed, .failed, .cancelled, .budgetExceeded: return nil
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

private enum AgentOperationSignal: Sendable {
    case operation(AgentRun)
    case observerFinished
}
#endif
