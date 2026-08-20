import Foundation

public protocol KnowledgeStore: Sendable {
    func loadDocument(sourceResourceID: UserFileResourceID) async throws -> KnowledgeDocument?
    func loadChunks(documentID: UUID) async throws -> [KnowledgeChunk]
    func listDocuments() async throws -> [KnowledgeDocument]

    /// Atomically replaces the stored representation for one source resource.
    /// Implementations must not expose a partially replaced document.
    func replaceDocument(
        _ document: KnowledgeDocument,
        chunks: [KnowledgeChunk]
    ) async throws
}

public actor KnowledgeIngestionEngine {
    private let extractor: any DocumentTextExtractor
    private let store: any KnowledgeStore
    private let chunker: KnowledgeChunker

    public init(
        extractor: any DocumentTextExtractor,
        store: any KnowledgeStore,
        chunker: KnowledgeChunker = KnowledgeChunker()
    ) {
        self.extractor = extractor
        self.store = store
        self.chunker = chunker
    }

    @discardableResult
    public func ingest(
        resourceID: UserFileResourceID
    ) async throws -> KnowledgeIngestionResult {
        let extracted = try await extractor.extract(resourceID: resourceID)
        guard extracted.sourceResourceID == resourceID else {
            throw KnowledgeIngestionError.sourceIdentityMismatch
        }
        guard !extracted.pages.isEmpty else {
            throw KnowledgeIngestionError.emptyDocument
        }

        let existing = try await store.loadDocument(sourceResourceID: resourceID)
        let now = Date()
        let documentID = existing?.id ?? UUID()
        let pageCount = extracted.pages.map(\.pageNumber).max() ?? 0

        let document = KnowledgeDocument(
            id: documentID,
            sourceResourceID: resourceID,
            displayName: extracted.displayName,
            mediaType: extracted.mediaType,
            pageCount: pageCount,
            metadata: extracted.metadata,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        let chunks = try chunker.chunk(extracted, documentID: documentID)
        guard !chunks.isEmpty else {
            throw KnowledgeIngestionError.noChunks
        }

        try await store.replaceDocument(document, chunks: chunks)
        return KnowledgeIngestionResult(document: document, chunks: chunks)
    }
}
