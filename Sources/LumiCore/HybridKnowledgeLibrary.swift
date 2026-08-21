import Foundation

public struct HybridRetrievalPolicy: Codable, Hashable, Sendable {
    public let sparseCandidates: Int
    public let denseCandidates: Int
    public let rrfK: Int
    public let sparseWeight: Double
    public let denseWeight: Double
    public let embeddingBatchSize: Int

    public init(
        sparseCandidates: Int = 24,
        denseCandidates: Int = 24,
        rrfK: Int = 60,
        sparseWeight: Double = 1,
        denseWeight: Double = 1,
        embeddingBatchSize: Int = 16
    ) {
        self.sparseCandidates = max(1, sparseCandidates)
        self.denseCandidates = max(1, denseCandidates)
        self.rrfK = max(1, rrfK)
        self.sparseWeight = max(0, sparseWeight)
        self.denseWeight = max(0, denseWeight)
        self.embeddingBatchSize = max(1, embeddingBatchSize)
    }
}

public struct HybridIngestionReport: Sendable {
    public let sparse: IngestionReport
    public let denseIndexed: Bool
    public let embeddingModel: String
    public let denseIssue: String?

    public init(
        sparse: IngestionReport,
        denseIndexed: Bool,
        embeddingModel: String,
        denseIssue: String?
    ) {
        self.sparse = sparse
        self.denseIndexed = denseIndexed
        self.embeddingModel = embeddingModel
        self.denseIssue = denseIssue
    }
}

/// Coordinates sparse and dense retrieval without making either backend responsible for fusion.
/// Dense failures intentionally degrade to sparse retrieval rather than taking the knowledge system offline.
public actor HybridKnowledgeLibrary: KnowledgeLibraryManaging {
    private let sparse: any KnowledgeStore
    private let vectors: any VectorIndex
    private let embeddings: any EmbeddingProvider
    private let chunker: TextChunker
    private let hasher: StableContentHasher
    private let policy: HybridRetrievalPolicy

    private var lastDenseIssue: String?

    public init(
        sparse: any KnowledgeStore,
        vectors: any VectorIndex,
        embeddings: any EmbeddingProvider,
        chunker: TextChunker = TextChunker(),
        hasher: StableContentHasher = StableContentHasher(),
        policy: HybridRetrievalPolicy = HybridRetrievalPolicy()
    ) {
        self.sparse = sparse
        self.vectors = vectors
        self.embeddings = embeddings
        self.chunker = chunker
        self.hasher = hasher
        self.policy = policy
    }

    public func ingest(_ document: IngestibleDocument) async throws -> HybridIngestionReport {
        let contentHash = hasher.hash(document.content)
        let source = KnowledgeSourceRecord(
            id: document.id,
            title: document.title,
            sourceType: document.sourceType,
            sourceURI: document.sourceURI,
            tags: document.tags,
            contentHash: contentHash,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt
        )
        let chunks = chunker.chunks(for: document, hasher: hasher)
        let sparseReport = IngestionReport(
            sourceID: document.id,
            contentHash: contentHash,
            chunkCount: chunks.count,
            characterCount: document.content.count
        )

        // Sparse storage is the durable minimum capability. If dense indexing fails later,
        // the document remains searchable and the stale dense copy is removed.
        try await sparse.replace(source: source, chunks: chunks)

        do {
            var records: [VectorRecord] = []
            records.reserveCapacity(chunks.count)

            var start = 0
            while start < chunks.count {
                let end = min(start + policy.embeddingBatchSize, chunks.count)
                let batch = Array(chunks[start..<end])
                let batchVectors = try await embeddings.embed(batch.map(\.text))
                guard batchVectors.count == batch.count else {
                    throw EmbeddingError.emptyEmbedding
                }

                for (chunk, vector) in zip(batch, batchVectors) {
                    records.append(
                        VectorRecord(
                            chunk: chunk,
                            modelID: embeddings.modelID,
                            vector: vector
                        )
                    )
                }
                start = end
            }

            try await vectors.replace(sourceID: document.id, records: records)
            lastDenseIssue = nil
            return HybridIngestionReport(
                sparse: sparseReport,
                denseIndexed: true,
                embeddingModel: embeddings.modelID,
                denseIssue: nil
            )
        } catch {
            // Never serve vectors from an older version of a source after sparse re-ingestion.
            try? await vectors.removeSource(id: document.id)
            lastDenseIssue = error.localizedDescription
            return HybridIngestionReport(
                sparse: sparseReport,
                denseIndexed: false,
                embeddingModel: embeddings.modelID,
                denseIssue: error.localizedDescription
            )
        }
    }

    public func listSources(limit: Int = 100) async throws -> [KnowledgeSourceRecord] {
        try await sparse.listSources(limit: limit)
    }

    public func removeSource(id: String) async throws {
        try await sparse.removeSource(id: id)
        do {
            try await vectors.removeSource(id: id)
            lastDenseIssue = nil
        } catch {
            lastDenseIssue = error.localizedDescription
            throw error
        }
    }

    public func search(_ query: String, limit: Int = 8) async -> [KnowledgeHit] {
        let finalLimit = max(0, limit)
        guard finalLimit > 0 else { return [] }

        async let sparseTask = sparse.search(query, limit: policy.sparseCandidates)

        var denseHits: [KnowledgeHit] = []
        do {
            let queryEmbeddings = try await embeddings.embed([query])
            guard let queryVector = queryEmbeddings.first else {
                throw EmbeddingError.emptyEmbedding
            }
            denseHits = try await vectors.search(
                vector: queryVector,
                modelID: embeddings.modelID,
                limit: policy.denseCandidates
            )
            lastDenseIssue = nil
        } catch {
            lastDenseIssue = error.localizedDescription
        }

        let sparseHits = await sparseTask
        return Self.reciprocalRankFusion(
            sparse: sparseHits,
            dense: denseHits,
            limit: finalLimit,
            policy: policy
        )
    }

    public func denseIssue() -> String? {
        lastDenseIssue
    }

    public static func reciprocalRankFusion(
        sparse: [KnowledgeHit],
        dense: [KnowledgeHit],
        limit: Int,
        policy: HybridRetrievalPolicy = HybridRetrievalPolicy()
    ) -> [KnowledgeHit] {
        guard limit > 0 else { return [] }

        var documents: [String: KnowledgeDocument] = [:]
        var scores: [String: Double] = [:]

        func key(for hit: KnowledgeHit) -> String {
            hit.document.chunkID ?? hit.document.id
        }

        for (rank, hit) in sparse.enumerated() {
            let id = key(for: hit)
            documents[id] = documents[id] ?? hit.document
            scores[id, default: 0] += policy.sparseWeight / Double(policy.rrfK + rank + 1)
        }

        for (rank, hit) in dense.enumerated() {
            let id = key(for: hit)
            documents[id] = documents[id] ?? hit.document
            scores[id, default: 0] += policy.denseWeight / Double(policy.rrfK + rank + 1)
        }

        return scores
            .compactMap { entry -> KnowledgeHit? in
                let (id, score) = entry
                guard let document = documents[id] else { return nil }
                return KnowledgeHit(document: document, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.document.id < rhs.document.id
                }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }
}
