import Foundation

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messageCount: Int = 0
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = max(0, messageCount)
    }
}

public struct ConversationTranscriptCursor: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let messageID: UUID

    public init(timestamp: Date, messageID: UUID) {
        self.timestamp = timestamp
        self.messageID = messageID
    }
}

public struct ConversationTranscriptPage: Codable, Hashable, Sendable {
    /// Always chronological (oldest -> newest) within this page.
    public let messages: [ChatMessage]
    /// Pass this cursor back to request the immediately older page. Nil means start of transcript.
    public let olderCursor: ConversationTranscriptCursor?
    public let hasOlder: Bool

    public init(
        messages: [ChatMessage],
        olderCursor: ConversationTranscriptCursor?,
        hasOlder: Bool
    ) {
        self.messages = messages
        self.olderCursor = olderCursor
        self.hasOlder = hasOlder
    }
}

/// Durable conversation metadata and transcripts. Long-term memory, knowledge, agent runs and
/// runtime telemetry intentionally have separate lifecycles and are not deleted when a chat changes.
public protocol ConversationStore: Sendable {
    func createConversation(id: UUID, title: String, createdAt: Date) async throws -> Conversation
    func conversation(id: UUID) async throws -> Conversation?
    func listConversations(limit: Int) async throws -> [Conversation]
    func renameConversation(id: UUID, title: String) async throws -> Conversation
    func deleteConversation(id: UUID) async throws

    func loadMessages(conversationID: UUID) async throws -> [ChatMessage]
    func loadTranscriptPage(
        conversationID: UUID,
        before cursor: ConversationTranscriptCursor?,
        limit: Int
    ) async throws -> ConversationTranscriptPage
    func append(_ message: ChatMessage, conversationID: UUID) async throws
    func clear(conversationID: UUID) async throws
}

public actor InMemoryConversationStore: ConversationStore {
    private var conversations: [UUID: Conversation] = [:]
    private var messages: [UUID: [ChatMessage]] = [:]

    public init() {}

    public func createConversation(id: UUID, title: String, createdAt: Date) throws -> Conversation {
        let cleanTitle = try Self.validatedTitle(title)
        if let existing = conversations[id] { return existing }

        let conversation = Conversation(
            id: id,
            title: cleanTitle,
            createdAt: createdAt,
            updatedAt: createdAt,
            messageCount: 0
        )
        conversations[id] = conversation
        messages[id] = messages[id] ?? []
        return conversation
    }

    public func conversation(id: UUID) -> Conversation? {
        conversations[id]
    }

    public func listConversations(limit: Int) -> [Conversation] {
        conversations.values
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func renameConversation(id: UUID, title: String) throws -> Conversation {
        guard let existing = conversations[id] else { throw ConversationStoreError.notFound }
        let cleanTitle = try Self.validatedTitle(title)
        let updated = Conversation(
            id: existing.id,
            title: cleanTitle,
            createdAt: existing.createdAt,
            updatedAt: Date(),
            messageCount: existing.messageCount
        )
        conversations[id] = updated
        return updated
    }

    public func deleteConversation(id: UUID) {
        conversations.removeValue(forKey: id)
        messages.removeValue(forKey: id)
    }

    public func loadMessages(conversationID: UUID) -> [ChatMessage] {
        messages[conversationID] ?? []
    }

    public func loadTranscriptPage(
        conversationID: UUID,
        before cursor: ConversationTranscriptCursor?,
        limit: Int
    ) -> ConversationTranscriptPage {
        let finalLimit = max(1, min(limit, 500))
        let ordered = (messages[conversationID] ?? []).sorted(by: Self.isEarlier)

        let endIndex: Int
        if let cursor,
           let index = ordered.firstIndex(where: { $0.id == cursor.messageID }) {
            endIndex = index
        } else if let cursor {
            endIndex = ordered.firstIndex(where: {
                $0.timestamp > cursor.timestamp
                    || ($0.timestamp == cursor.timestamp && $0.id.uuidString >= cursor.messageID.uuidString)
            }) ?? ordered.count
        } else {
            endIndex = ordered.count
        }

        let startIndex = max(0, endIndex - finalLimit)
        let pageMessages = Array(ordered[startIndex..<endIndex])
        let hasOlder = startIndex > 0
        let olderCursor = hasOlder ? pageMessages.first.map {
            ConversationTranscriptCursor(timestamp: $0.timestamp, messageID: $0.id)
        } : nil

        return ConversationTranscriptPage(
            messages: pageMessages,
            olderCursor: olderCursor,
            hasOlder: hasOlder
        )
    }

    public func append(_ message: ChatMessage, conversationID: UUID) throws {
        if conversations[conversationID] == nil {
            _ = try createConversation(id: conversationID, title: "New chat", createdAt: message.timestamp)
        }
        messages[conversationID, default: []].append(message)
        refreshMetadata(id: conversationID, updatedAt: message.timestamp)
    }

    /// Clears only the transcript while preserving the chat metadata entry.
    public func clear(conversationID: UUID) {
        messages[conversationID] = []
        guard let existing = conversations[conversationID] else { return }
        conversations[conversationID] = Conversation(
            id: existing.id,
            title: existing.title,
            createdAt: existing.createdAt,
            updatedAt: Date(),
            messageCount: 0
        )
    }

    private func refreshMetadata(id: UUID, updatedAt: Date) {
        guard let existing = conversations[id] else { return }
        conversations[id] = Conversation(
            id: existing.id,
            title: existing.title,
            createdAt: existing.createdAt,
            updatedAt: updatedAt,
            messageCount: messages[id]?.count ?? 0
        )
    }

    private static func isEarlier(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.timestamp < rhs.timestamp
    }

    private static func validatedTitle(_ title: String) throws -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ConversationStoreError.invalidTitle }
        return String(clean.prefix(120))
    }
}

public enum ConversationStoreError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case migrationFailed(String)
    case statementFailed(String)
    case writeFailed(String)
    case notFound
    case invalidTitle

    public var errorDescription: String? {
        switch self {
        case .openFailed(let detail): return "Could not open Lumi storage: \(detail)"
        case .migrationFailed(let detail): return "Could not migrate Lumi storage: \(detail)"
        case .statementFailed(let detail): return "Could not read Lumi storage: \(detail)"
        case .writeFailed(let detail): return "Could not write Lumi storage: \(detail)"
        case .notFound: return "Conversation was not found."
        case .invalidTitle: return "Conversation title must not be empty."
        }
    }
}
