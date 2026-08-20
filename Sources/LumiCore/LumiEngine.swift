import Foundation

public actor LumiEngine {
    public static let defaultConversationID = UUID(uuidString: "8E7FA7AF-9B0D-4E9C-B9FA-4112C8336C01")!

    public let memory: MemoryStore
    public let reflections: ReflectionJournal
    public let knowledge: KnowledgeIndex
    public let conversationID: UUID

    private let router: IntentRouter
    private let prompts: PromptRegistry
    private let llm: any LLMClient
    private let conversationStore: any ConversationStore

    private var hasRestoredConversation = false
    private var storageIssue: String?

    public init(
        llm: any LLMClient = ResilientLLMClient(primary: OllamaClient()),
        prompts: PromptRegistry = .bundled(),
        router: IntentRouter = IntentRouter(),
        memory: MemoryStore = MemoryStore(),
        reflections: ReflectionJournal = ReflectionJournal(),
        knowledge: KnowledgeIndex = KnowledgeIndex(documents: LumiEngine.bootstrapKnowledge),
        conversationStore: any ConversationStore = InMemoryConversationStore(),
        conversationID: UUID = LumiEngine.defaultConversationID
    ) {
        self.llm = llm
        self.prompts = prompts
        self.router = router
        self.memory = memory
        self.reflections = reflections
        self.knowledge = knowledge
        self.conversationStore = conversationStore
        self.conversationID = conversationID
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

        return await finalize(
            completion: completion,
            input: prepared.cleanInput,
            intent: prepared.intent,
            context: prepared.context,
            profile: prepared.profile
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
                                profile: prepared.profile
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
    }

    private func prepare(_ request: LumiRequest) async -> PreparedRequest {
        await ensureConversationRestored()

        let cleanInput = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = router.detect(cleanInput)
        let selectedProfileName = request.profileOverride ?? profileName(for: intent)
        let profile = prompts.profile(named: selectedProfileName)

        _ = await appendMessage(role: .user, content: cleanInput)
        let context = await knowledge.search(cleanInput, limit: 4)
        let history = await memory.recent(limit: 18)
        let systemPrompt = composeSystemPrompt(profile: profile, context: context)

        return PreparedRequest(
            cleanInput: cleanInput,
            intent: intent,
            context: context,
            profile: profile,
            modelRequest: ModelRequest(
                messages: history,
                systemPrompt: systemPrompt,
                profile: profile
            )
        )
    }

    private func finalize(
        completion: ModelResponse,
        input: String,
        intent: LumiIntent,
        context: [KnowledgeHit],
        profile: PromptProfile
    ) async -> LumiReply {
        let assistant = await appendMessage(role: .assistant, content: completion.content)
        await reflections.record(input: input, intent: intent, response: completion.content)

        return LumiReply(
            message: assistant,
            intent: intent,
            context: context,
            profile: profile.name,
            runtime: completion.runtime
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

    private func composeSystemPrompt(profile: PromptProfile, context: [KnowledgeHit]) -> String {
        guard !context.isEmpty else { return profile.system }
        let rendered = context.enumerated().map { index, hit in
            "[\(index + 1)] \(hit.document.title)\n\(hit.document.text)"
        }.joined(separator: "\n\n")

        return """
        \(profile.system)

        Relevant local context follows. Use it when it helps, but do not claim it is authoritative if it is incomplete.
        \(rendered)
        """
    }

    public static let bootstrapKnowledge: [KnowledgeDocument] = [
        KnowledgeDocument(
            id: "lumi-architecture",
            title: "Lumi V3 architecture",
            text: "Lumi V3 separates orchestration, memory, intent routing, prompt profiles, knowledge retrieval, model access, reflection logging, and the SwiftUI presentation layer. Reflection is telemetry, not consciousness.",
            tags: ["lumi", "architecture", "v3"]
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
            text: "Conversation memory uses a bounded working buffer and can be backed by durable conversation storage. Long-term semantic memory remains a separate future layer.",
            tags: ["memory", "privacy"]
        )
    ]
}
