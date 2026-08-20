import Foundation

public extension LumiEngine {
    /// Production-style local default: conversation history and the knowledge library share the
    /// same SQLite database file while using separate typed stores/connections.
    static func persistentDefault() -> LumiEngine {
        let databaseURL = SQLiteConversationStore.defaultDatabaseURL()
        return LumiEngine(
            knowledge: SQLiteKnowledgeStore(databaseURL: databaseURL),
            conversationStore: SQLiteConversationStore(databaseURL: databaseURL)
        )
    }
}
