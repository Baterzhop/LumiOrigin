import Foundation

public extension LumiEngine {
    /// Production-style local default: conversation history, long-term memory, sparse knowledge and
    /// vectors share one SQLite file through separate typed stores. Dense retrieval uses local Ollama
    /// embeddings when available and degrades to FTS5 when the embedding model is offline.
    static func persistentDefault() -> LumiEngine {
        let databaseURL = SQLiteConversationStore.defaultDatabaseURL()
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

        return LumiEngine(
            longTermMemory: memoryRuntime,
            knowledge: hybrid,
            conversationStore: SQLiteConversationStore(databaseURL: databaseURL)
        )
    }
}
