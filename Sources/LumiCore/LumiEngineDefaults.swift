import Foundation

public extension LumiEngine {
    /// Production-style local default: conversation history, long-term memory, sparse knowledge,
    /// vectors, tool audit events, agent checkpoints and metadata-only runtime traces share one
    /// SQLite file through separate typed stores. ToolRuntime exposes only sandboxed read-only
    /// workspace tools; AgentRuntime remains explicit.
    static func persistentDefault() -> LumiEngine {
        let databaseURL = SQLiteConversationStore.defaultDatabaseURL()
        let llm = ModelRouter.localOllamaDefault()
        let sparse = SQLiteKnowledgeStore(databaseURL: databaseURL)
        let vectors = SQLiteVectorIndex(databaseURL: databaseURL)
        let hybrid = HybridKnowledgeLibrary(
            sparse: sparse,
            vectors: vectors,
            embeddings: OllamaEmbeddingProvider()
        )
        let memoryRuntime = MemoryRuntime(
            repository: SQLiteMemoryRepository(databaseURL: databaseURL),
            writePolicy: .explicitOnly
        )
        let telemetry = RuntimeTelemetry(
            store: SQLiteRuntimeTraceStore(databaseURL: databaseURL)
        )

        let workspaceURL = defaultWorkspaceURL(databaseURL: databaseURL)
        try? FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let sandbox = WorkspaceSandbox(rootURL: workspaceURL)
        let registry = ToolRegistry(tools: [
            ListWorkspaceFilesTool(sandbox: sandbox),
            ReadWorkspaceTextFileTool(sandbox: sandbox)
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

        return LumiEngine(
            llm: llm,
            longTermMemory: memoryRuntime,
            knowledge: hybrid,
            conversationStore: SQLiteConversationStore(databaseURL: databaseURL),
            toolRuntime: toolRuntime,
            agentRuntime: agentRuntime,
            telemetry: telemetry
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
