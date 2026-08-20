import Foundation

public protocol MemoryStore: Sendable {
    func load(key: String) async throws -> UserMemoryRecord?
    func load(id: UUID) async throws -> UserMemoryRecord?
    func listActive() async throws -> [UserMemoryRecord]
    func history(memoryID: UUID) async throws -> [MemoryRevision]
    func upsert(_ request: MemoryWriteRequest) async throws -> MemoryWriteResult
    func forget(key: String, expectedRevision: Int?) async throws -> UserMemoryRecord?
}

public enum MemoryStoreError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidKey
    case keyTooLong(Int)
    case invalidValue
    case valueTooLong(Int)
    case invalidConfidence(Double)
    case revisionConflict(key: String, expected: Int?, actual: Int?)
    case openFailed(String)
    case statementFailed(String)
    case executionFailed(String)
    case corruptData(String)

    public var description: String {
        switch self {
        case .invalidKey:
            return "Memory key cannot be empty after canonicalization."
        case .keyTooLong(let count):
            return "Memory key is too long (\(count) characters)."
        case .invalidValue:
            return "Memory value cannot be empty."
        case .valueTooLong(let count):
            return "Memory value is too long (\(count) characters)."
        case .invalidConfidence(let confidence):
            return "Memory confidence must be finite and between 0 and 1; received \(confidence)."
        case .revisionConflict(let key, let expected, let actual):
            return "Memory revision conflict for \(key): expected \(expected.map(String.init) ?? "none"), actual \(actual.map(String.init) ?? "none")."
        case .openFailed(let message):
            return "Memory SQLite open failed: \(message)"
        case .statementFailed(let message):
            return "Memory SQLite statement failed: \(message)"
        case .executionFailed(let message):
            return "Memory SQLite execution failed: \(message)"
        case .corruptData(let message):
            return "Memory SQLite data is invalid: \(message)"
        }
    }
}

/// Validates and canonicalizes memory operations before they reach persistence.
///
/// Persistent writes require optimistic revision matching for replacement and
/// deletion. A caller cannot silently overwrite an existing memory by omitting
/// the current revision.
public struct MemoryService: Sendable {
    private let store: any MemoryStore

    public init(store: any MemoryStore) {
        self.store = store
    }

    public func load(key rawKey: String) async throws -> UserMemoryRecord? {
        let key = try Self.validatedKey(rawKey)
        return try await store.load(key: key)
    }

    public func listActive() async throws -> [UserMemoryRecord] {
        try await store.listActive()
    }

    public func history(memoryID: UUID) async throws -> [MemoryRevision] {
        try await store.history(memoryID: memoryID)
    }

    @discardableResult
    public func remember(
        key rawKey: String,
        kind: MemoryKind,
        value rawValue: String,
        confidence: Double = 1.0,
        provenance: MemoryProvenance,
        expectedRevision: Int? = nil
    ) async throws -> MemoryWriteResult {
        let key = try Self.validatedKey(rawKey)
        let value = try Self.validatedValue(rawValue)
        try Self.validateConfidence(confidence)
        if let expectedRevision, expectedRevision < 1 {
            throw MemoryStoreError.revisionConflict(
                key: key,
                expected: expectedRevision,
                actual: nil
            )
        }

        return try await store.upsert(
            MemoryWriteRequest(
                key: key,
                kind: kind,
                value: value,
                confidence: confidence,
                provenance: provenance,
                expectedRevision: expectedRevision
            )
        )
    }

    @discardableResult
    public func forget(
        key rawKey: String,
        expectedRevision: Int?
    ) async throws -> UserMemoryRecord? {
        let key = try Self.validatedKey(rawKey)
        if let expectedRevision, expectedRevision < 1 {
            throw MemoryStoreError.revisionConflict(
                key: key,
                expected: expectedRevision,
                actual: nil
            )
        }
        return try await store.forget(key: key, expectedRevision: expectedRevision)
    }

    public static func validatedKey(_ rawKey: String) throws -> String {
        let key = MemoryValidation.canonicalKey(rawKey)
        guard !key.isEmpty else { throw MemoryStoreError.invalidKey }
        guard key.count <= MemoryValidation.maximumKeyCharacters else {
            throw MemoryStoreError.keyTooLong(key.count)
        }
        return key
    }

    public static func validatedValue(_ rawValue: String) throws -> String {
        let value = MemoryValidation.normalizedValue(rawValue)
        guard !value.isEmpty else { throw MemoryStoreError.invalidValue }
        guard value.count <= MemoryValidation.maximumValueCharacters else {
            throw MemoryStoreError.valueTooLong(value.count)
        }
        return value
    }

    public static func validateConfidence(_ confidence: Double) throws {
        guard confidence.isFinite, (0.0...1.0).contains(confidence) else {
            throw MemoryStoreError.invalidConfidence(confidence)
        }
    }
}
