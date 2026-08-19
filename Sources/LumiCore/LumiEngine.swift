import Foundation

public actor LumiEngine {
    public let memory: MemoryStore
    public let reflections: ReflectionJournal
    public let knowledge: KnowledgeIndex

    private let router: IntentRouter
    private let prompts: PromptRegistry
    private let llm: any LLMClient

    public init(
        llm: any LLMClient = ResilientLLMClient(primary: OllamaClient()),
        prompts: PromptRegistry = .bundled(),
        router: IntentRouter = IntentRouter(),
        memory: MemoryStore = MemoryStore(),
        reflections: ReflectionJournal = ReflectionJournal(),
        knowledge: KnowledgeIndex = KnowledgeIndex(documents: LumiEngine.bootstrapKnowledge)
    ) {
        self.llm = llm
        self.prompts = prompts
        self.router = router
        self.memory = memory
        self.reflections = reflections
        self.knowledge = knowledge
    }

    public func respond(to input: String, profile requestedProfile: String? = nil) async -> LumiReply {
        let cleanInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = router.detect(cleanInput)
        let selectedProfileName = requestedProfile ?? profileName(for: intent)
        let profile = prompts.profile(named: selectedProfileName)

        _ = await memory.append(role: .user, content: cleanInput)
        let context = await knowledge.search(cleanInput, limit: 4)
        let history = await memory.recent(limit: 18)
        let systemPrompt = composeSystemPrompt(profile: profile, context: context)

        let responseText: String
        do {
            responseText = try await llm.complete(
                messages: history,
                systemPrompt: systemPrompt,
                profile: profile
            )
        } catch {
            responseText = "I couldn't reach the configured language model: \(error.localizedDescription)"
        }

        let assistant = await memory.append(role: .assistant, content: responseText)
        await reflections.record(input: cleanInput, intent: intent, response: responseText)

        return LumiReply(
            message: assistant,
            intent: intent,
            context: context,
            profile: profile.name
        )
    }

    public func messages() async -> [ChatMessage] {
        await memory.all()
    }

    public func recentReflections(limit: Int = 20) async -> [ReflectionEvent] {
        await reflections.recent(limit: limit)
    }

    public func clearConversation() async {
        await memory.clear()
        await reflections.clear()
    }

    public func availableProfiles() -> [String] {
        prompts.names
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
            text: "Conversation memory is bounded in-memory state. It stores recent user and assistant messages and can be cleared from the interface. Durable memory should be added as a separate persistence layer.",
            tags: ["memory", "privacy"]
        )
    ]
}
