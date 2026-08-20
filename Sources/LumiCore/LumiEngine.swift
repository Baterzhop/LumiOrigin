import Foundation

public actor LumiEngine {
    public static let defaultConversationID = UUID(uuidString: "8E7FA7AF-9B0D-4E9C-B9FA-4112C8336C01")!

    public let memory: MemoryStore
    public let reflections: ReflectionJournal
    public let knowledge: any KnowledgeRetrieving
    public let conversationID: UUID

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
        router: IntentRouter = IntentRouter(),
        memory: MemoryStore = MemoryStore(),
        reflections: ReflectionJournal = ReflectionJournal(),
        knowledge: any KnowledgeRetrieving = KnowledgeIndex(documents: LumiEngine.bootstrapKnowledge),
        conversationStore: any ConversationStore = InMemoryConversationStore(),
        conversationID: UUID = LumiEngine.defaultConversationID,
        contextManager: ContextBudgetManager = ContextBudgetManager(),
        citationAssembler: CitationAssembler = CitationAssembler()
    ) {
        self.llm = llm
        self.prompts = prompts
        self.router = router
        self.memory = memory
        self.reflections = reflections
        self.knowledge = knowledge
        self.conversationStore = conversationStore
        self.conversationID = conversationID
        self.contextManager = contextManager
        self.citationAssembler = citationAssembler
    }

    public func respond(to input: String, profile requestedProfile: String? = nil) async -> LumiReply {
        await respond(
            LumiRequest(
                input: input,
                profileOverride: requestedProfile
            )
        )
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
            context: prepared.context,
            profile: prepared.profile,
            contextBudget: prepared.contextBudget
        )
    }

    public func streamRespond(
        to input: String,
        profile requestedProfile: String? = nil
    ) async -> AsyncThrowingStream<LumiStreamEvent, Error> {
        await streamRespond(
            LumiRequest(
                input: input,
                profileOverride: requestedProfile
            )
        )
    }

    public func streamRespond(_ request: LumiRequest) async -> AsyncThrowingStream<LumiStreamEvent, Error> {
        let prepared = await prepare(request)

        if !prepared.contextBudget.fits {
            let reply = await finalize(
                completion: contextOverflowResponse(prepared.contextBudget),
                input: prepared.cleanInput,
                intent: prepared.intent,
                context: prepared.context,
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
                                context: prepared.context,
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

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
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

    private struct PreparedRequest: Sendable {
        let cleanInput: String
        let intent: LumiIntent
        let context: [KnowledgeHit]
        let profile: PromptProfile
        let modelRequest: ModelRequest
        let contextBudget: ContextBudgetReport
    }

    private func prepare(_ request: LumiRequest) async -> PreparedRequest {
        await ensureConversationRestored()

        let cleanInput = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = router.detect(cleanInput)
        let selectedProfileName = request.profileOverride ?? profileName(for: intent)
        let profile = prompts.profile(named: selectedProfileName)

        _ = await appendMessage(role: .user, content: cleanInput)

        // Direct chat should not pay the retrieval/embedding cost on every turn. Until the
        // capability router arrives, knowledge intent or an explicit knowledge profile is the
        // boundary that enables retrieval.
        let contextCandidates: [KnowledgeHit]
        if intent == .knowledge || profile.name == "knowledge" {
            contextCandidates = await knowledge.search(cleanInput, limit: 8)
        } else {
            contextCandidates = []
        }

        let fullHistory = await memory.all()
        let packed = contextManager.pack(
            profile: profile,
            history: fullHistory,
            knowledge: contextCandidates
        )

        return PreparedRequest(
            cleanInput: cleanInput,
            intent: intent,
            context: packed.knowledge,
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
        context: [KnowledgeHit],
        profile: PromptProfile,
        contextBudget: ContextBudgetReport
    ) async -> LumiReply {
        let assistant = await appendMessage(role: .assistant, content: completion.content)
        await reflections.record(input: input, intent: intent, response: completion.content)
        let citationReport = citationAssembler.assemble(
            response: completion.content,
            evidence: context
        )

        return LumiReply(
            message: assistant,
            intent: intent,
            context: context,
            profile: profile.name,
            runtime: completion.runtime,
            contextBudget: contextBudget,
            citationReport: citationReport
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
            text: "Lumi V4 separates orchestration, durable conversation persistence, bounded working memory, token-budgeted context packing, retrieval, model access, and the SwiftUI presentation layer. Reflection is telemetry, not consciousness.",
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
            title: "Conversation memory",
            text: "Conversation memory uses a bounded working buffer backed by durable conversation storage. Long-term semantic memory remains a separate future layer.",
            tags: ["memory", "privacy"]
        )
    ]
}
