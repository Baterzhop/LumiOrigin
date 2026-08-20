import Foundation

public actor MemoryRuntime {
    private let repository: any MemoryRepository
    public let writePolicy: MemoryWritePolicy

    public init(
        repository: any MemoryRepository,
        writePolicy: MemoryWritePolicy = .explicitOnly
    ) {
        self.repository = repository
        self.writePolicy = writePolicy
    }

    @discardableResult
    public func remember(
        _ content: String,
        kind: MemoryKind = .semantic,
        source: MemorySource = .explicitUser,
        confidence: Double = 1,
        importance: Double = 0.6,
        expiresAt: Date? = nil,
        isPinned: Bool = false,
        tags: [String] = []
    ) async throws -> MemoryRecord {
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MemoryError.emptyContent }

        if writePolicy == .explicitOnly, source.kind != .explicitUser, source.kind != .imported {
            throw MemoryError.policyDenied
        }

        let record = MemoryRecord(
            kind: kind,
            content: clean,
            source: source,
            confidence: confidence,
            importance: importance,
            expiresAt: expiresAt,
            isPinned: isPinned,
            tags: tags
        )
        try await repository.upsert(record)
        return record
    }

    @discardableResult
    public func update(
        id: UUID,
        kind: MemoryKind? = nil,
        content: String? = nil,
        confidence: Double? = nil,
        importance: Double? = nil,
        expiresAt: Date?? = nil,
        isPinned: Bool? = nil,
        tags: [String]? = nil
    ) async throws -> MemoryRecord {
        guard let existing = try await repository.record(id: id) else {
            throw MemoryError.notFound
        }

        if let content, content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemoryError.emptyContent
        }

        let updated = existing.replacing(
            kind: kind,
            content: content?.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence,
            importance: importance,
            expiresAt: expiresAt,
            isPinned: isPinned,
            tags: tags
        )
        try await repository.upsert(updated)
        return updated
    }

    public func relevant(to query: String, limit: Int = 6) async -> [MemoryHit] {
        let hits = await repository.search(query, limit: limit)
        let ids = hits.map(\.record.id)
        if !ids.isEmpty {
            try? await repository.markUsed(ids: ids, at: Date())
        }
        return hits
    }

    public func all(limit: Int = 100) async throws -> [MemoryRecord] {
        try await repository.list(limit: limit)
    }

    public func record(id: UUID) async throws -> MemoryRecord? {
        try await repository.record(id: id)
    }

    public func forget(id: UUID) async throws {
        try await repository.delete(id: id)
    }

    @discardableResult
    public func purgeExpired(referenceDate: Date = Date()) async throws -> Int {
        try await repository.clearExpired(referenceDate: referenceDate)
    }
}
