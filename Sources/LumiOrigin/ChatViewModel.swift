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

    @Published var conversations: [Conversation] = []
    @Published var activeConversationID: UUID?
    @Published var conversationTitleDraft = ""
    @Published var isSessionReady = false
    @Published var conversationError: String?
    @Published var hasOlderMessages = false
    @Published var isLoadingOlderMessages = false

    @Published var agentGoal = ""
    @Published var activeAgentRun: AgentRun?
    @Published var recentAgentRuns: [AgentRun] = []
    @Published var isAgentRunning = false
    @Published var agentError: String?
    @Published var agentActivity: String?

    let profiles = ["auto", "chat", "knowledge", "coding", "reflection"]
    private let sessionRuntime: LumiRuntimeContainer?
    private var engine: LumiEngine
    private var sendTask: Task<Void, Never>?
    private var agentTask: Task<Void, Never>?
    private var transcriptCursor: ConversationTranscriptCursor?
    private let transcriptPageSize = 60

    init(runtime: LumiRuntimeContainer = .persistentDefault()) {
        self.sessionRuntime = runtime
        self.engine = runtime.makeEngine(conversationID: LumiEngine.defaultConversationID)
        bootstrapConversationSessions()
        refreshMemories()
        refreshAgentRuns()
    }

    /// Test/embedding convenience for callers that provide one explicitly scoped engine.
    /// Multi-session paging controls are disabled because the engine's dependency graph is opaque here.
    init(engine: LumiEngine) {
        self.sessionRuntime = nil
        self.engine = engine
        self.isSessionReady = true
        restoreHistory()
        refreshMemories()
        refreshAgentRuns()
    }

    var activeConversation: Conversation? {
        guard let activeConversationID else { return nil }
        return conversations.first(where: { $0.id == activeConversationID })
    }

    var canChangeConversation: Bool {
        isSessionReady && !isSending && !isAgentRunning && !isLoadingOlderMessages
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !isAgentRunning, isSessionReady else { return }

        input = ""
        streamingText = ""
        lastError = nil
        citationReport = .empty
        isSending = true
        status = "Generating"
        messages.append(ChatMessage(role: .user, content: text))

        let profileOverride = selectedProfile == "auto" ? nil : selectedProfile
        let requestEngine = engine
        let conversationID = activeConversationID

        sendTask = Task {
            await autoTitleConversationIfNeeded(id: conversationID, userText: text)
            let stream = await requestEngine.streamRespond(to: text, profile: profileOverride)

            do {
                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .token(let token):
                        streamingText += token

                    case .completed(let reply):
                        // The request engine is immutable to one session. If UI session state ever
                        // changes independently, do not project old-session messages into the new UI.
                        if conversationID == activeConversationID {
                            await refreshNewestTranscriptPage(
                                conversationID: conversationID,
                                fallbackEngine: requestEngine,
                                preservingLoadedOlder: true
                            )
                            streamingText = ""
                            lastIntent = reply.intent
                            classification = reply.classification
                            contextHits = reply.context
                            relevantMemories = reply.memories
                            contextBudget = reply.contextBudget
                            citationReport = reply.citationReport
                            runtime = reply.runtime
                            applyRuntimeStatus(reply.runtime)
                            await applyPersistenceStatusIfNeeded(engine: requestEngine)
                        }
                        await reloadConversations()
                    }
                }
            } catch {
                if conversationID == activeConversationID {
                    await refreshNewestTranscriptPage(
                        conversationID: conversationID,
                        fallbackEngine: requestEngine,
                        preservingLoadedOlder: true
                    )
                    streamingText = ""

                    if Task.isCancelled {
                        status = "Stopped"
                    } else {
                        status = "Model error"
                        lastError = error.localizedDescription
                    }
                    await applyPersistenceStatusIfNeeded(engine: requestEngine)
                }
                await reloadConversations()
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

    func loadOlderMessages() {
        guard !isLoadingOlderMessages,
              hasOlderMessages,
              let cursor = transcriptCursor,
              let conversationID = activeConversationID,
              let sessionRuntime else { return }

        isLoadingOlderMessages = true
        conversationError = nil

        Task {
            do {
                let page = try await sessionRuntime.transcriptPage(
                    conversationID: conversationID,
                    before: cursor,
                    limit: transcriptPageSize
                )
                guard conversationID == activeConversationID else {
                    isLoadingOlderMessages = false
                    return
                }

                let existingIDs = Set(messages.map(\.id))
                let uniqueOlder = page.messages.filter { !existingIDs.contains($0.id) }
                messages = uniqueOlder + messages
                transcriptCursor = page.olderCursor
                hasOlderMessages = page.hasOlder
            } catch {
                conversationError = error.localizedDescription
            }
            isLoadingOlderMessages = false
        }
    }

    func createConversation() {
        guard canChangeConversation, let sessionRuntime else { return }
        conversationError = nil

        Task {
            do {
                let conversation = try await sessionRuntime.createConversation(title: "New chat")
                try await activateConversation(conversation, runtime: sessionRuntime)
                await reloadConversations()
                status = "New chat"
            } catch {
                conversationError = error.localizedDescription
                status = "Storage error"
            }
        }
    }

    func selectConversation(_ conversation: Conversation) {
        guard canChangeConversation,
              conversation.id != activeConversationID,
              let sessionRuntime else { return }
        conversationError = nil

        Task {
            do {
                try await activateConversation(conversation, runtime: sessionRuntime)
                status = messages.isEmpty ? "Local-first" : "History restored"
            } catch {
                conversationError = error.localizedDescription
                status = "Storage error"
            }
        }
    }

    func saveConversationTitle() {
        guard canChangeConversation,
              let id = activeConversationID,
              let sessionRuntime else { return }
        let clean = conversationTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        Task {
            do {
                _ = try await sessionRuntime.renameConversation(id: id, title: clean)
                await reloadConversations()
            } catch {
                conversationError = error.localizedDescription
            }
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        guard canChangeConversation, let sessionRuntime else { return }
        conversationError = nil

        Task {
            do {
                try await sessionRuntime.deleteConversation(id: conversation.id)
                let remaining = try await sessionRuntime.conversations(limit: 100)

                if conversation.id == activeConversationID {
                    let replacement: Conversation
                    if let first = remaining.first {
                        replacement = first
                    } else {
                        replacement = try await sessionRuntime.createConversation(title: "New chat")
                    }
                    try await activateConversation(replacement, runtime: sessionRuntime)
                }

                await reloadConversations()
            } catch {
                conversationError = error.localizedDescription
                status = "Storage error"
            }
        }
    }

    func refreshConversations() {
        Task { await reloadConversations() }
    }

    func startAgent() {
        let goal = agentGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !isAgentRunning, !isSending else { return }

        agentError = nil
        agentActivity = "Starting agent"
        isAgentRunning = true
        status = "Agent running"
        agentTask?.cancel()
        let requestEngine = engine

        agentTask = Task {
            do {
                guard let agentRuntime = await requestEngine.agentRuntime else {
                    throw AgentRuntimeError.invalidState("AgentRuntime is not configured for this LumiEngine.")
                }
                let events = await agentRuntime.events()
                let run = try await executeAgentOperation(observing: events) {
                    try await requestEngine.startAgent(goal: goal)
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
        let requestEngine = engine
        agentTask = Task {
            do {
                let cancelled = try await requestEngine.cancelAgent(runID: run.id)
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
        let requestEngine = engine
        Task {
            do {
                recentAgentRuns = try await requestEngine.recentAgentRuns(limit: 20)
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
        let requestEngine = engine

        Task {
            await requestEngine.clearConversation()
            transcriptCursor = nil
            hasOlderMessages = false
            isLoadingOlderMessages = false
            resetConversationPresentation(messages: [])
            status = "Local-first"
            isSending = false
            await applyPersistenceStatusIfNeeded(engine: requestEngine)
            await reloadConversations()
        }
    }

    func saveMemoryDraft() {
        let clean = memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let requestEngine = engine

        Task {
            do {
                if let editingMemoryID {
                    _ = try await requestEngine.updateMemory(id: editingMemoryID, content: clean)
                } else {
                    _ = try await requestEngine.remember(clean, kind: .semantic, importance: 0.7)
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
        let requestEngine = engine
        Task {
            do {
                try await requestEngine.forgetMemory(id: memory.id)
                relevantMemories.removeAll { $0.record.id == memory.id }
                refreshMemories()
            } catch {
                lastError = error.localizedDescription
                status = "Memory error"
            }
        }
    }

    func refreshMemories() {
        let requestEngine = engine
        Task {
            do {
                storedMemories = try await requestEngine.storedMemories(limit: 50)
            } catch MemoryError.unavailable {
                storedMemories = []
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func bootstrapConversationSessions() {
        guard let sessionRuntime else {
            isSessionReady = true
            restoreHistory()
            return
        }

        Task {
            do {
                let initial = try await sessionRuntime.initialConversation()
                try await activateConversation(initial, runtime: sessionRuntime)
                await reloadConversations()
                isSessionReady = true
                status = messages.isEmpty ? "Local-first" : "History restored"
            } catch {
                isSessionReady = false
                conversationError = error.localizedDescription
                status = "Storage error"
            }
        }
    }

    private func activateConversation(
        _ conversation: Conversation,
        runtime: LumiRuntimeContainer
    ) async throws {
        let newEngine = runtime.makeEngine(conversationID: conversation.id)
        // Restore the full durable history into bounded working memory so compaction can be rebuilt,
        // but expose only a paged durable transcript to presentation.
        _ = try await newEngine.restoreConversation()
        let page = try await runtime.transcriptPage(
            conversationID: conversation.id,
            before: nil,
            limit: transcriptPageSize
        )

        engine = newEngine
        activeConversationID = conversation.id
        conversationTitleDraft = conversation.title
        transcriptCursor = page.olderCursor
        hasOlderMessages = page.hasOlder
        isLoadingOlderMessages = false
        resetConversationPresentation(messages: page.messages)
        refreshMemories()
        refreshAgentRuns()
    }

    private func refreshNewestTranscriptPage(
        conversationID: UUID?,
        fallbackEngine: LumiEngine,
        preservingLoadedOlder: Bool
    ) async {
        guard let conversationID,
              let sessionRuntime else {
            let workingMessages = await fallbackEngine.messages()
            messages = workingMessages.filter { $0.role != .system }
            return
        }

        do {
            let page = try await sessionRuntime.transcriptPage(
                conversationID: conversationID,
                before: nil,
                limit: transcriptPageSize
            )
            guard conversationID == activeConversationID else { return }

            if preservingLoadedOlder,
               let oldestNewestPage = page.messages.first {
                let latestIDs = Set(page.messages.map(\.id))
                let preservedOlder = messages.filter {
                    $0.role != .system
                        && !latestIDs.contains($0.id)
                        && $0.timestamp <= oldestNewestPage.timestamp
                }

                if preservedOlder.isEmpty {
                    messages = page.messages
                    transcriptCursor = page.olderCursor
                    hasOlderMessages = page.hasOlder
                } else {
                    messages = preservedOlder + page.messages
                    // Keep the existing cursor: it points immediately before the oldest loaded page.
                }
            } else {
                messages = page.messages
                transcriptCursor = page.olderCursor
                hasOlderMessages = page.hasOlder
            }
        } catch {
            conversationError = error.localizedDescription
            let workingMessages = await fallbackEngine.messages()
            messages = workingMessages.filter { $0.role != .system }
        }
    }

    private func reloadConversations() async {
        guard let sessionRuntime else { return }
        do {
            conversations = try await sessionRuntime.conversations(limit: 100)
            if let activeConversationID,
               let active = conversations.first(where: { $0.id == activeConversationID }),
               conversationTitleDraft.isEmpty || active.title != "New chat" {
                conversationTitleDraft = active.title
            }
            conversationError = nil
        } catch {
            conversationError = error.localizedDescription
        }
    }

    private func autoTitleConversationIfNeeded(id: UUID?, userText: String) async {
        guard let id, let sessionRuntime else { return }
        do {
            guard let conversation = try await sessionRuntime.conversation(id: id),
                  conversation.messageCount == 0,
                  conversation.title == "New chat"
            else { return }

            let title = Self.suggestedConversationTitle(from: userText)
            _ = try await sessionRuntime.renameConversation(id: id, title: title)
            if id == activeConversationID { conversationTitleDraft = title }
            await reloadConversations()
        } catch {
            conversationError = error.localizedDescription
        }
    }

    private static func suggestedConversationTitle(from input: String) -> String {
        let normalized = input
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "New chat" }
        let prefix = String(normalized.prefix(56))
        return normalized.count > 56 ? prefix + "…" : prefix
    }

    private func resetConversationPresentation(messages restored: [ChatMessage]) {
        messages = restored
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
        let requestEngine = engine

        agentTask = Task {
            do {
                guard let agentRuntime = await requestEngine.agentRuntime else {
                    throw AgentRuntimeError.invalidState("AgentRuntime is not configured for this LumiEngine.")
                }
                let events = await agentRuntime.events()
                let resumed = try await executeAgentOperation(observing: events) {
                    try await requestEngine.resumeAgent(
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
        let requestEngine = engine
        Task {
            do {
                let restored = try await requestEngine.restoreConversation()
                messages = restored.filter { $0.role != .system }
                transcriptCursor = nil
                hasOlderMessages = false
                if !restored.isEmpty { status = "History restored" }
            } catch {
                status = "Storage error"
                lastError = error.localizedDescription
            }
        }
    }

    private func applyPersistenceStatusIfNeeded(engine: LumiEngine) async {
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
