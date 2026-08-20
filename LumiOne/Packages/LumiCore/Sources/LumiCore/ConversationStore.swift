import Foundation

public protocol ConversationStore: Sendable {
    func loadConversation(id: UUID) async throws -> Conversation?
    func saveConversation(_ conversation: Conversation) async throws
}

public enum StorageBootResult: Sendable {
    case ready(SQLiteConversationStore)
    case safeMode(reason: String)
}

public enum StorageBootstrap {
    public static func openSQLite(at url: URL) -> StorageBootResult {
        do {
            return .ready(try SQLiteConversationStore(url: url))
        } catch {
            return .safeMode(reason: String(describing: error))
        }
    }
}
