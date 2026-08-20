import Foundation

public actor LumiEngine {
    public static let defaultConversationID = UUID(uuidString: "8E7FA7AF-9B0D-4E9C-B9FA-4112C8336C01")!

    public let memory: MemoryStore
    public let longTermMemory: MemoryRuntime?
    public let reflections: ReflectionJournal
    public let knowledge: any KnowledgeRetrieving
    public let toolRuntime: ToolRuntime?
    public let agentRuntime: AgentRuntime?
    public let conversationID: UUID

    private let classifier: any RequestClassifying
    private let router: IntentRouter
    private let prompts: PromptRegistry
    private let llm: any LLMClient
    private let conversationStore: any ConversationStore
    private let contextManager: ContextBudgetManager
    private let citationAssembler: CitationAssembler

    private var hasRestoredConversation = false
    private var storageIssue: String?

    public init(
        llm: any LLMClient = ResilientLLMClient(primary: OllamaClient()),
        prompts: PromptRegistry = .bundled(),
        classifier: any RequestClassifying = HeuristicRequestClassifier(),
        router: IntentRouter = IntentRouter(),
        memory: MemoryStore = MemoryStore(),
        longTermMemory: MemoryRuntime? = nil,
        reflections: ReflectionJournal = ReflectionJournal(),
        knowledge: any KnowledgeRetrieving = KnowledgeIndex(documents: LumiEngine.bootstrapKnowledge),
        conversationStore: any ConversationStore = InMemoryConversationStore(),
        toolRuntime: ToolRuntime? = nil,
        agentRuntime: AgentRuntime? = nil,
        conversationID: UUID = LumiEngine.defaultConversationID,
        contextManager: ContextBudgetManager = ContextBudgetManager(),
        citationAssembler: CitationAssembler = CitationAssembler()
    ) {
        self.llm = llm
        self.prompts = prompts
        self.classifier = classifier
        self.router = router
        self.memory = memory
        self.longTermMemory = longTermMemory
        self.reflections = reflections
        self.knowledge = knowledge
        self.conversationStore = conversationStore
        self.toolRuntime = toolRuntime
        self.agentRuntime = agentRuntime
        self.conversationID = conversationID
        self.contextManager = contextManager
        self.citationAssembler = citationAssembler
    }

    public func respond(to input: String, profile requestedProfile: String? = nil) async -> LumiReply {
        await respond(LumiRequest(input: input, profileOverride: requestedProfile))
    }

    public func respond(_ request: LumiRequest) async -> LumiReply {
        let prepared = await prepare(request)

        let completion: ModelResponse
        if !prepared.contextBudget.fits {
            completion = contextOverflowResponse(prepared.contextBudget)
        } else {
            do {
                completion = try await llm.complete(prepared.modelRequest)
            } catch {
                completion = ModelResponse(
                    content: "I couldn't reach the configured language model: \(error.localizedDescription)",
                    runtime: RuntimeMetadata(
                        provider: .unknown,
                        model: "unavailable",
                        fallbackUsed: false,
                        finishReason: .error
                    )
                )
            }
        }

        return await finalize(
            completion: completion,
            input: prepared.cleanInput,
            intent: prepared.intent,
            classification: prepared.classification,
            context: prepared.context,
            memories: prepared.memories,
            profile: prepared.profile,
            contextBudget: prepared.contextBudget
        )
    }

    public func streamRespond(
        to input: String,
        profile requestedProfile: String? = nil
    ) async -> AsyncThrowingStream<LumiStreamEvent, Error> {
        await streamRespond(LumiRequest(input: input, profileOverride: requestedProfile))
    }

    public func streamRespond(_ request: LumiRequest) async -> AsyncThrowingStream<LumiStreamEvent, Error> {
        let prepared = await prepare(request)

        if !prepared.contextBudget.fits {
            let reply = await finalize(
                completion: contextOverflowResponse(prepared.contextBudget),
                input: prepared.cleanInput,
                intent: prepared.intent,
                classification: prepared.classification,
                context: prepared.context,
                memories: prepared.memories,
                profile: prepared.profile,
                contextBudget: prepared.contextBudget
            )
            return AsyncThrowingStream { continuation in
                continuation.yield(.completed(reply))
                continuation.finish()
            }
        }

        let modelStream = llm.stream(prepared.modelRequest)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in modelStream {
                        try Task.checkCancellation()

                        switch event {
                        case .token(let token):
                            continuation.yield(.token(token))

                        case .completed(let completion):
                            let reply = await self.finalize(
                                completion: completion,
                                input: prepared.cleanInput,
                                intent: prepared.intent,
                                classification: prepared.classification,
                                context: prepared.context,
                                memories: prepared.memories,
                                profile: prepared.profile,
                                contextBudget: prepared.contextBudget
                            )
                            continuation.yield(.completed(reply))
                            continuation.finish()
                            return
                        }
                    }

                    continuation.finish(throwing: LumiRuntimeError.invalidResponse)
                } catch is CancellationError {
                    continuation.finish(throwing: LumiRuntimeError.cancelled)
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: LumiRuntimeError.cancelled)
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    @discardableResult
    public func restoreConversation() async throws -> [ChatMessage] {
        do {
            let restored = try await conversationStore.loadMessages(conversationID: conversationID)
            await memory.replace(with: restored)
            hasRestoredConversation = true
            storageIssue = nil
            return restored
        } catch {
            storageIssue = error.localizedDescription
            throw error
        }
    }

    public func messages() async -> [ChatMessage] {
        await ensureConversationRestored()
        return await memory.all()
    }

    public func recentReflections(limit: Int = 20) async -> [ReflectionEvent] {
        await reflections.recent(limit: limit)
    }

    public func persistenceIssue() -> String? {
        storageIssue
    }

    /// Clears only the durable conversation transcript and bounded working buffer.
    /// Long-term memory and agent-run history have independent lifecycles.
    public func clearConversation() async {
        await memory.clear()
        await reflections.clear()
        hasRestoredConversation = true

        do {
            try await conversationStore.clear(conversationID: conversationID)
            storageIssue = nil
        } catch {
            storageIssue = error.localizedDescription
        }
    }

    public func availableProfiles() -> [String] {
        prompts.names
    }

    public func availableTools() async -> [ToolDefinition] {
        guard let toolRuntime else { return [] }
        return await toolRuntime.availableTools()
    }

    /// Executes one already-constructed tool call through the permission, sandbox and audit layers.
    /// Normal chat generation does not call this method automatically.
    public func executeTool(
        _ call: ToolCall,
        confirmation: ToolConfirmation? = nil
    ) async -> ToolResult {
        guard let toolRuntime else {
            return ToolResult(
                callID: call.id,
                toolName: call.toolName,
                status: .denied,
                error: "ToolRuntime is not configured for this LumiEngine."
            )
        }
        return await toolRuntime.execute(call, confirmation: confirmation)
    }

    public func recentToolAudit(limit: Int = 50) async -> [ToolAuditEvent] {
        guard let toolRuntime else { return [] }
        return await toolRuntime.recentAudit(limit: limit)
    }

    public func toolAuditIssue() async -> String? {
        guard let toolRuntime else { return nil }
        return await toolRuntime.auditIssue()
    }

    /// Explicitly starts the bounded agent state machine. `respond()` remains non-agentic.
    public func startAgent(
        goal: String,
        budget: AgentBudget = AgentBudget()
    ) async throws -> AgentRun {
        guard let agentRuntime else {
            throw AgentRuntimeError.invalidState("AgentRuntime is not configured for this LumiEngine.")
        }
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let classification = classifier.classify(LumiRequest(input: cleanGoal))
        return try await agentRuntime.start(
            goal: cleanGoal,
            classification: classification,
            budget: budget
        )
    }

    public func resumeAgent(
        runID: UUID,
        confirmation: ToolConfirmation
    ) async throws -> AgentRun {
        guard let agentRuntime else {
            throw AgentRuntimeError.invalidState("AgentRuntime is not configured for this LumiEngine.")
        }
        return try await agentRuntime.resume(runID: runID, confirmation: confirmation)
    }

    public func cancelAgent(runID: UUID) async throws -> AgentRun {
        guard let agentRuntime else {
            throw AgentRuntimeError.invalidState("AgentRuntime is not configured for this LumiEngine.")
        }
        return try await agentRuntime.cancel(runID: runID)
    }

    public func agentRun(id: UUID) async throws -> AgentRun? {
        guard let agentRuntime else {
            throw AgentRuntimeError.invalidState("AgentRuntime is not configured for this LumiEngine.")
        }
        return try await agentRuntime.load(runID: id)
    }

    public func recentAgentRuns(limit: Int = 20) async throws -> [AgentRun] {
        guard let agentRuntime else {
            throw AgentRuntimeError.invalidState("AgentRuntime is not configured for this LumiEngine.")
        }
        return try await agentRuntime.recentRuns(limit: limit)
    }

    @discardableResult
    public func remember(
        _ content: String,
        kind: MemoryKind = .semantic,
        importance: Double = 0.6,
        expiresAt: Date? = nil,
        isPinned: Bool = false,
        tags: [String] = []
    ) async throws -> MemoryRecord {
        guard let longTermMemory else { throw MemoryError.unavailable }
        return try await longTermMemory.remember(
            content,
            kind: kind,
            source: .explicitUser,
            confidence: 1,
            importance: importance,
            expiresAt: expiresAt,
            isPinned: isPinned,
            tags: tags
        )
    }

    public func storedMemories(limit: Int = 100) async throws -> [MemoryRecord] {
        guard let longTermMemory else { throw MemoryError.unavailable }
        return try await longTermMemory.all(limit: limit)
    }

    @discardableResult
    public func updateMemory(
        id: UUID,
        kind: MemoryKind? = nil,
        content: String? = nil,
        confidence: Double? = nil,
        importance: Double? = nil,
        expiresAt: Date?? = nil,
        isPinned: Bool? = nil,
        tags: [String]? = nil
    ) async throws -> MemoryRecord {
        guard let longTermMemory else { throw MemoryError.unavailable }
        return try await longTermMemory.update(
            id: id,
            kind: kind,
            content: content,
            confidence: confidence,
            importance: importance,
            expiresAt: expiresAt,
            isPinned: isPinned,
            tags: tags
        )
    }

    public func forgetMemory(id: UUID) async throws {
        guard let longTermMemory else { throw MemoryError.unavailable }
        try await longTermMemory.forget(id: id)
    }

    private struct PreparedRequest: Sendable {
        let cleanInput: String
        let intent: LumiIntent
        let classification: RequestClassification
        let context: [KnowledgeHit]
        let memories: [MemoryHit]
        let profile: PromptProfile
        let modelRequest: ModelRequest
        let contextBudget: ContextBudgetReport
    }

    private func prepare(_ request: LumiRequest) async -> PreparedRequest {
        await ensureConversationRestored()

        let cleanInput = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let classifiedRequest = LumiRequest(
            id: request.id,
            input: cleanInput,
            profileOverride: request.profileOverride,
            createdAt: request.createdAt
        )
        let classification = classifier.classify(classifiedRequest)
        let intent = router.intent(for: classification)
        let selectedProfileName = request.profileOverride ?? profileName(for: intent)
        let baseProfile = prompts.profile(named: selectedProfileName)
        let profile = profileWithCapabilityBoundary(baseProfile, classification: classification)

        _ = await appendMessage(role: .user, content: cleanInput)

        let contextCandidates: [KnowledgeHit]
        if classification.capabilities.contains(.retrieval) || classification.capabilities.contains(.files) {
            contextCandidates = await knowledge.search(cleanInput, limit: 8)
        } else {
            contextCandidates = []
        }

        let memoryCandidates: [MemoryHit]
        if classification.capabilities.contains(.memory), let longTermMemory, !cleanInput.isEmpty {
            memoryCandidates = await longTermMemory.relevant(to: cleanInput, limit: 8)
        } else {
            memoryCandidates = []
        }

        let fullHistory = await memory.all()
        let packed = contextManager.pack(
            profile: profile,
            history: fullHistory,
            knowledge: contextCandidates,
            memories: memoryCandidates
        )

        return PreparedRequest(
            cleanInput: cleanInput,
            intent: intent,
            classification: classification,
            context: packed.knowledge,
            memories: packed.memories,
            profile: profile,
            modelRequest: ModelRequest(
                messages: packed.messages,
                systemPrompt: packed.systemPrompt,
                profile: profile
            ),
            contextBudget: packed.report
        )
    }

    private func finalize(
        completion: ModelResponse,
        input: String,
        intent: LumiIntent,
        classification: RequestClassification,
        context: [KnowledgeHit],
        memories: [MemoryHit],
        profile: PromptProfile,
        contextBudget: ContextBudgetReport
    ) async -> LumiReply {
        let assistant = await appendMessage(role: .assistant, content: completion.content)
        await reflections.record(input: input, intent: intent, response: completion.content)
        let citationReport = citationAssembler.assemble(response: completion.content, evidence: context)

        return LumiReply(
            message: assistant,
            intent: intent,
            classification: classification,
            context: context,
            memories: memories,
            profile: profile.name,
            runtime: completion.runtime,
            contextBudget: contextBudget,
            citationReport: citationReport
        )
    }

    private func profileWithCapabilityBoundary(
        _ profile: PromptProfile,
        classification: RequestClassification
    ) -> PromptProfile {
        var notices: [String] = []

        if classification.capabilities.contains(.tools) {
            if toolRuntime == nil {
                notices.append("External tools/actions are not configured in this runtime.")
            } else {
                notices.append(
                    "A sandboxed ToolRuntime exists, but normal chat generation cannot invoke tools automatically in this phase. Do not claim that an external action or file operation was executed unless an actual ToolResult is supplied by the runtime. AgentRuntime, when configured, must be started explicitly."
                )
            }
        }

        if classification.capabilities.contains(.web) {
            notices.append("Live web access is not connected in this runtime.")
        }

        guard !notices.isEmpty else { return profile }

        let notice = """
        Runtime capability boundary:
        \(notices.map { "- " + $0 }.joined(separator: "\n"))
        Clearly distinguish what you can answer from local context from what would require a missing or not-yet-invoked capability.
        """

        return PromptProfile(
            name: profile.name,
            system: profile.system + "\n\n" + notice,
            temperature: profile.temperature,
            topP: profile.topP,
            maxTokens: profile.maxTokens
        )
    }

    private func contextOverflowResponse(_ report: ContextBudgetReport) -> ModelResponse {
        ModelResponse(
            content: "The request is too large for the configured model context window (estimated \(report.estimatedInputTokens) input tokens; budget \(report.inputBudgetTokens)). Reduce the request size or configure a larger LUMI_CONTEXT_WINDOW.",
            runtime: RuntimeMetadata(
                provider: .unknown,
                model: "context-budget",
                fallbackUsed: false,
                finishReason: .error
            )
        )
    }

    private func ensureConversationRestored() async {
        guard !hasRestoredConversation else { return }
        do {
            _ = try await restoreConversation()
        } catch {
            hasRestoredConversation = true
        }
    }

    private func appendMessage(role: ChatRole, content: String) async -> ChatMessage {
        let message = await memory.append(role: role, content: content)

        do {
            try await conversationStore.append(message, conversationID: conversationID)
            storageIssue = nil
        } catch {
            storageIssue = error.localizedDescription
        }

        return message
    }

    private func profileName(for intent: LumiIntent) -> String {
        switch intent {
        case .coding: return "coding"
        case .knowledge: return "knowledge"
        case .reflection: return "reflection"
        case .tool, .chat: return "chat"
        }
    }

    public static let bootstrapKnowledge: [KnowledgeDocument] = [
        KnowledgeDocument(
            id: "lumi-architecture",
            title: "Lumi V4 architecture",
            text: "Lumi V4 separates orchestration, durable conversation persistence, bounded working memory, token-budgeted context packing, retrieval, model access, tool execution, and the SwiftUI presentation layer. Reflection is telemetry, not consciousness.",
            tags: ["lumi", "architecture", "v4"]
        ),
        KnowledgeDocument(
            id: "lumi-model",
            title: "Local model provider",
            text: "By default Lumi calls an Ollama-compatible chat endpoint at http://127.0.0.1:11434/api/chat and falls back to a deterministic local response if the model cannot be reached.",
            tags: ["ollama", "local", "llm"]
        ),
        KnowledgeDocument(
            id: "lumi-memory",
            title: "Conversation and long-term memory",
            text: "Conversation history, bounded working memory, and user-controlled long-term memory are separate layers. Long-term memory is persisted locally and has an explicit lifecycle.",
            tags: ["memory", "privacy", "v4"]
        ),
        KnowledgeDocument(
            id: "lumi-tools",
            title: "ToolRuntime and AgentRuntime security boundary",
            text: "ToolRuntime supports typed, audited and sandboxed read-only tools. AgentRuntime can plan, execute, observe and replan only through ToolRuntime, with bounded budgets and persisted checkpoints. Normal chat does not automatically execute actions.",
            tags: ["tools", "agent", "security", "v4"]
        )
    ]
}
