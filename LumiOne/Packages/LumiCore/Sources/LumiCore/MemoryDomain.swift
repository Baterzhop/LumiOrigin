import Foundation

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case profile
    case preference
    case project
    case routine
    case context
    case other
}

public struct MemoryProvenance: Codable, Equatable, Sendable {
    public enum SourceKind: String, Codable, Sendable {
        case manualUserEntry
        case explicitUserStatement
        case approvedModelProposal
        case imported
    }

    public let sourceKind: SourceKind
    public let conversationID: UUID?
    public let messageID: UUID?
    public let note: String?

    public init(
        sourceKind: SourceKind,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        note: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.conversationID = conversationID
        self.messageID = messageID
        self.note = note
    }
}

public struct MemoryRevision: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let memoryID: UUID
    public let revision: Int
    public let kind: MemoryKind
    public let value: String
    public let confidence: Double
    public let provenance: MemoryProvenance
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        memoryID: UUID,
        revision: Int,
        kind: MemoryKind,
        value: String,
        confidence: Double,
        provenance: MemoryProvenance,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.memoryID = memoryID
        self.revision = revision
        self.kind = kind
        self.value = value
        self.confidence = confidence
        self.provenance = provenance
        self.createdAt = createdAt
    }
}

public struct UserMemoryRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let key: String
    public let currentRevision: MemoryRevision
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        key: String,
        currentRevision: MemoryRevision,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.key = key
        self.currentRevision = currentRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var kind: MemoryKind { currentRevision.kind }
    public var value: String { currentRevision.value }
    public var confidence: Double { currentRevision.confidence }
    public var provenance: MemoryProvenance { currentRevision.provenance }
    public var revision: Int { currentRevision.revision }
}

public struct MemoryWriteRequest: Codable, Equatable, Sendable {
    public let key: String
    public let kind: MemoryKind
    public let value: String
    public let confidence: Double
    public let provenance: MemoryProvenance
    public let expectedRevision: Int?

    public init(
        key: String,
        kind: MemoryKind,
        value: String,
        confidence: Double = 1.0,
        provenance: MemoryProvenance,
        expectedRevision: Int? = nil
    ) {
        self.key = key
        self.kind = kind
        self.value = value
        self.confidence = confidence
        self.provenance = provenance
        self.expectedRevision = expectedRevision
    }
}

public struct MemoryWriteResult: Codable, Equatable, Sendable {
    public let record: UserMemoryRecord
    public let previousRevision: MemoryRevision?

    public init(record: UserMemoryRecord, previousRevision: MemoryRevision?) {
        self.record = record
        self.previousRevision = previousRevision
    }

    public var created: Bool { previousRevision == nil }
}

public enum MemoryValidation {
    public static let maximumKeyCharacters = 96
    public static let maximumValueCharacters = 4_096

    /// Canonical memory keys are locale-independent lowercase Unicode
    /// alphanumeric segments separated by a single dot.
    public static func canonicalKey(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var output = String.UnicodeScalarView()
        var needsSeparator = false

        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !output.isEmpty {
                    output.append(".")
                }
                output.append(scalar)
                needsSeparator = false
            } else if !output.isEmpty {
                needsSeparator = true
            }
        }

        return String(output)
    }

    public static func normalizedValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
