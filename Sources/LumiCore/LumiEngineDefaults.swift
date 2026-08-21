import Foundation

/// Process-level service graph. Session engines share durable/global services while each engine owns
/// an isolated bounded working-memory buffer for exactly one immutable conversation ID.
public struct LumiRuntimeContainer: Sendable {
    public let llm: any LLMClient
    public let longTermMemory: MemoryRuntime?
    public let knowledge: any KnowledgeRetrieving
    public let conversationStore: any ConversationStore
    public let toolRuntime: ToolRuntime?
    public let agentRuntime: AgentRuntime?
    public let telemetry: RuntimeTelemetry?

    public init(
        llm: any LLMClient,
        longTermMemory: MemoryRuntime? = nil,
        knowledge: any KnowledgeRetrieving,
        conversationStore: any ConversationStore,
        toolRuntime: ToolRuntime? = nil,
        agentRuntime: AgentRuntime? = nil,
        telemetry: RuntimeTelemetry? = nil
    ) {
        self.llm = llm
        self.longTermMemory = longTermMemory
        self.knowledge = knowledge
        self.conversationStore = conversationStore
        self.toolRuntime = toolRuntime
        self.agentRuntime = agentRuntime
        self.telemetry = telemetry
    }

    public func makeEngine(conversationID: UUID) -> LumiEngine {
        LumiEngine(
            llm: llm,
            longTermMemory: longTermMemory,
            knowledge: knowledge,
            conversationStore: conversationStore,
            toolRuntime: toolRuntime,
            agentRuntime: agentRuntime,
            telemetry: telemetry,
            conversationID: conversationID
        )
    }

    @discardableResult
    public func createConversation(
        id: UUID = UUID(),
        title: String = "New chat",
        createdAt: Date = Date()
    ) async throws -> Conversation {
        try await conversationStore.createConversation(id: id, title: title, createdAt: createdAt)
    }

    public func conversation(id: UUID) async throws -> Conversation? {
        try await conversationStore.conversation(id: id)
    }

    public func conversations(limit: Int = 100) async throws -> [Conversation] {
        try await conversationStore.listConversations(limit: max(0, min(limit, 500)))
    }

    @discardableResult
    public func renameConversation(id: UUID, title: String) async throws -> Conversation {
        try await conversationStore.renameConversation(id: id, title: title)
    }

    public func deleteConversation(id: UUID) async throws {
        try await conversationStore.deleteConversation(id: id)
    }

    /// Restores the most recently active durable chat. On a fresh install it creates the historic
    /// default conversation ID so older single-chat databases remain migration-compatible.
    public func initialConversation(
        fallbackID: UUID = LumiEngine.defaultConversationID
    ) async throws -> Conversation {
        if let recent = try await conversations(limit: 1).first {
            return recent
        }
        return try await createConversation(id: fallbackID, title: "New chat")
    }

    public static func persistentDefault() -> LumiRuntimeContainer {
        let databaseURL = SQLiteConversationStore.defaultDatabaseURL()
        let configuration = LocalModelConfiguration.environment()
        let llm = ModelRouter.localOllamaDefault(configuration: configuration)
        let hybrid = LumiEngine.persistentKnowledgeLibrary(
            databaseURL: databaseURL,
            configuration: configuration
        )
        let memoryRuntime = MemoryRuntime(
            repository: SQLiteMemoryRepository(databaseURL: databaseURL),
            writePolicy: .explicitOnly
        )
        let telemetry = RuntimeTelemetry(
            store: SQLiteRuntimeTraceStore(databaseURL: databaseURL)
        )

        let workspaceURL = LumiEngine.defaultWorkspaceURL(databaseURL: databaseURL)
        try? FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let sandbox = WorkspaceSandbox(rootURL: workspaceURL)
        let registry = ToolRegistry(tools: [
            ListWorkspaceFilesTool(sandbox: sandbox),
            ReadWorkspaceTextFileTool(sandbox: sandbox),
            KnowledgeSearchTool(knowledge: hybrid),
            MemorySearchTool(memory: memoryRuntime)
        ])
        let toolRuntime = ToolRuntime(
            registry: registry,
            policy: ToolPermissionPolicy(
                allowLowRiskReadOnlyWithoutConfirmation: true,
                writeToolsEnabled: false
            ),
            auditStore: SQLiteToolAuditStore(databaseURL: databaseURL)
        )
        let agentRuntime = AgentRuntime(
            planner: LLMAgentPlanner(llm: llm),
            tools: toolRuntime,
            store: SQLiteAgentRunStore(databaseURL: databaseURL)
        )

        return LumiRuntimeContainer(
            llm: llm,
            longTermMemory: memoryRuntime,
            knowledge: hybrid,
            conversationStore: SQLiteConversationStore(databaseURL: databaseURL),
            toolRuntime: toolRuntime,
            agentRuntime: agentRuntime,
            telemetry: telemetry
        )
    }
}

public extension LumiEngine {
    /// Backward-compatible single-session convenience. Multi-conversation UI should keep one
    /// `LumiRuntimeContainer` and create session engines from it.
    static func persistentDefault(
        conversationID: UUID = LumiEngine.defaultConversationID
    ) -> LumiEngine {
        LumiRuntimeContainer.persistentDefault().makeEngine(conversationID: conversationID)
    }

    static func persistentKnowledgeLibrary(
        databaseURL: URL = SQLiteConversationStore.defaultDatabaseURL(),
        configuration: LocalModelConfiguration = .environment()
    ) -> HybridKnowledgeLibrary {
        HybridKnowledgeLibrary(
            sparse: SQLiteKnowledgeStore(databaseURL: databaseURL),
            vectors: SQLiteVectorIndex(databaseURL: databaseURL),
            embeddings: OllamaEmbeddingProvider(
                endpoint: configuration.embeddingEndpoint,
                model: configuration.embeddingModel
            )
        )
    }

    static func defaultWorkspaceURL(
        databaseURL: URL = SQLiteConversationStore.defaultDatabaseURL()
    ) -> URL {
        if let configured = ProcessInfo.processInfo.environment["LUMI_WORKSPACE"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }

        return databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("Workspace", isDirectory: true)
    }
}
