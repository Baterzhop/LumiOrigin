import Foundation

public struct ExtractedDocumentPage: Codable, Equatable, Sendable {
    /// One-based page number from the source document.
    public let pageNumber: Int
    public let text: String

    public init(pageNumber: Int, text: String) {
        self.pageNumber = pageNumber
        self.text = text
    }
}

public struct ExtractedDocument: Codable, Equatable, Sendable {
    public let sourceResourceID: UserFileResourceID
    public let displayName: String
    public let mediaType: String
    public let pages: [ExtractedDocumentPage]
    public let metadata: [String: JSONValue]

    public init(
        sourceResourceID: UserFileResourceID,
        displayName: String,
        mediaType: String,
        pages: [ExtractedDocumentPage],
        metadata: [String: JSONValue] = [:]
    ) {
        self.sourceResourceID = sourceResourceID
        self.displayName = displayName
        self.mediaType = mediaType
        self.pages = pages
        self.metadata = metadata
    }
}

public protocol DocumentTextExtractor: Sendable {
    /// Extracts text only from a user-file resource already registered by the host.
    /// Implementations must never interpret the resource ID as a filesystem path.
    func extract(resourceID: UserFileResourceID) async throws -> ExtractedDocument
}

public enum DocumentExtractionError: Error, CustomStringConvertible, Sendable, Equatable {
    case unsupportedResource(String)
    case invalidDocument(String)
    case noExtractableText(String)
    case invalidPageNumber(Int)

    public var description: String {
        switch self {
        case .unsupportedResource(let name):
            return "The selected resource is not a supported document: \(name)."
        case .invalidDocument(let name):
            return "The selected document could not be parsed: \(name)."
        case .noExtractableText(let name):
            return "The selected document contains no extractable text: \(name)."
        case .invalidPageNumber(let page):
            return "Document extraction returned an invalid page number: \(page)."
        }
    }
}

public struct KnowledgeDocument: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceResourceID: UserFileResourceID
    public let displayName: String
    public let mediaType: String
    public let pageCount: Int
    public let metadata: [String: JSONValue]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourceResourceID: UserFileResourceID,
        displayName: String,
        mediaType: String,
        pageCount: Int,
        metadata: [String: JSONValue] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceResourceID = sourceResourceID
        self.displayName = displayName
        self.mediaType = mediaType
        self.pageCount = pageCount
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct KnowledgeChunk: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let ordinal: Int
    public let pageStart: Int
    public let pageEnd: Int
    public let text: String

    public init(
        id: UUID = UUID(),
        documentID: UUID,
        ordinal: Int,
        pageStart: Int,
        pageEnd: Int,
        text: String
    ) {
        self.id = id
        self.documentID = documentID
        self.ordinal = ordinal
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.text = text
    }
}

public struct KnowledgeIngestionResult: Equatable, Sendable {
    public let document: KnowledgeDocument
    public let chunks: [KnowledgeChunk]

    public init(document: KnowledgeDocument, chunks: [KnowledgeChunk]) {
        self.document = document
        self.chunks = chunks
    }
}

public enum KnowledgeIngestionError: Error, CustomStringConvertible, Sendable, Equatable {
    case emptyDocument
    case invalidPageOrder
    case sourceIdentityMismatch
    case noChunks

    public var description: String {
        switch self {
        case .emptyDocument:
            return "Document extraction returned no pages."
        case .invalidPageOrder:
            return "Document pages must have unique, strictly increasing one-based page numbers."
        case .sourceIdentityMismatch:
            return "Document extractor returned content for a different user-file resource."
        case .noChunks:
            return "Document extraction produced no indexable text chunks."
        }
    }
}
