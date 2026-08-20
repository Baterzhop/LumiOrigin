import Foundation

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol ConversationStore: Sendable {
    func loadMessages(conversationID: UUID) async throws -> [ChatMessage]
    func append(_ message: ChatMessage, conversationID: UUID) async throws
    func clear(conversationID: UUID) async throws
}

public actor InMemoryConversationStore: ConversationStore {
    private var messages: [UUID: [ChatMessage]] = [:]

    public init() {}

    public func loadMessages(conversationID: UUID) -> [ChatMessage] {
        messages[conversationID] ?? []
    }

    public func append(_ message: ChatMessage, conversationID: UUID) {
        messages[conversationID, default: []].append(message)
    }

    public func clear(conversationID: UUID) {
        messages[conversationID] = []
    }
}

public enum ConversationStoreError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case migrationFailed(String)
    case statementFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let detail): return "Could not open Lumi storage: \(detail)"
        case .migrationFailed(let detail): return "Could not migrate Lumi storage: \(detail)"
        case .statementFailed(let detail): return "Could not read Lumi storage: \(detail)"
        case .writeFailed(let detail): return "Could not write Lumi storage: \(detail)"
        }
    }
}
