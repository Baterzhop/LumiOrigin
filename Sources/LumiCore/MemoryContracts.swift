import Foundation

public enum MemoryKind: String, Codable, Sendable, CaseIterable, Hashable {
    case semantic
    case episodic
    case summary
}

public enum MemorySourceKind: String, Codable, Sendable, Hashable {
    case explicitUser
    case conversationDerived
    case imported
    case system
}

public struct MemorySource: Codable, Hashable, Sendable {
    public let kind: MemorySourceKind
    public let conversationID: UUID?
    public let messageID: UUID?
    public let note: String?

    public init(
        kind: MemorySourceKind,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        note: String? = nil
    ) {
        self.kind = kind
        self.conversationID = conversationID
        self.messageID = messageID
        self.note = note
    }

    public static let explicitUser = MemorySource(kind: .explicitUser)
}

public struct MemoryRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: MemoryKind
    public let content: String
    public let source: MemorySource
    public let confidence: Double
    public let importance: Double
    public let createdAt: Date
    public let updatedAt: Date
    public let lastUsedAt: Date?
    public let expiresAt: Date?
    public let isPinned: Bool
    public let tags: [String]

    public init(
        id: UUID = UUID(),
        kind: MemoryKind,
        content: String,
        source: MemorySource,
        confidence: Double = 1,
        importance: Double = 0.5,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        expiresAt: Date? = nil,
        isPinned: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.confidence = min(max(confidence, 0), 1)
        self.importance = min(max(importance, 0), 1)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.isPinned = isPinned
        self.tags = tags
    }

    public func replacing(
        kind: MemoryKind? = nil,
        content: String? = nil,
        confidence: Double? = nil,
        importance: Double? = nil,
        expiresAt: Date?? = nil,
        isPinned: Bool? = nil,
        tags: [String]? = nil,
        updatedAt: Date = Date()
    ) -> MemoryRecord {
        MemoryRecord(
            id: id,
            kind: kind ?? self.kind,
            content: content ?? self.content,
            source: source,
            confidence: confidence ?? self.confidence,
            importance: importance ?? self.importance,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt,
            expiresAt: expiresAt ?? self.expiresAt,
            isPinned: isPinned ?? self.isPinned,
            tags: tags ?? self.tags
        )
    }
}

public struct MemoryHit: Codable, Hashable, Sendable {
    public let record: MemoryRecord
    public let score: Double

    public init(record: MemoryRecord, score: Double) {
        self.record = record
        self.score = score
    }
}

public enum MemoryWritePolicy: String, Codable, Sendable, Hashable {
    /// V1 default. Lumi stores long-term memory only after an explicit user or application action.
    case explicitOnly

    /// Reserved for a later extraction workflow that must surface candidates for user review.
    case reviewedExtraction
}

public enum MemoryError: Error, LocalizedError, Sendable {
    case emptyContent
    case notFound
    case unavailable
    case policyDenied
    case openFailed(String)
    case migrationFailed(String)
    case statementFailed(String)
    case writeFailed(String)
    case invalidQuery

    public var errorDescription: String? {
        switch self {
        case .emptyContent: return "Memory content is empty."
        case .notFound: return "Memory record was not found."
        case .unavailable: return "Long-term memory is not configured for this Lumi runtime."
        case .policyDenied: return "The current memory policy does not allow this write without explicit review."
        case .openFailed(let detail): return "Could not open the memory database: \(detail)"
        case .migrationFailed(let detail): return "Could not migrate the memory database: \(detail)"
        case .statementFailed(let detail): return "Memory database statement failed: \(detail)"
        case .writeFailed(let detail): return "Could not write memory data: \(detail)"
        case .invalidQuery: return "The memory search query contains no searchable terms."
        }
    }
}

public protocol MemoryRepository: Sendable {
    func upsert(_ record: MemoryRecord) async throws
    func record(id: UUID) async throws -> MemoryRecord?
    func list(limit: Int) async throws -> [MemoryRecord]
    func search(_ query: String, limit: Int) async -> [MemoryHit]
    func delete(id: UUID) async throws
    func clearExpired(referenceDate: Date) async throws -> Int
    func markUsed(ids: [UUID], at: Date) async throws
}
