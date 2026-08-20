import XCTest
@testable import LumiCore

final class HybridRetrievalTests: XCTestCase {
    func testVectorIndexPersistsAndRanksByCosineSimilarity() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-vectors-\(UUID().uuidString).sqlite3")
        let sourceID = "vehicles"
        let carChunk = makeChunk(
            id: "vehicles:car",
            sourceID: sourceID,
            text: "An automobile engine converts fuel into mechanical work."
        )
        let fruitChunk = makeChunk(
            id: "vehicles:fruit",
            sourceID: sourceID,
            text: "A banana is a fruit."
        )

        let firstIndex = SQLiteVectorIndex(databaseURL: databaseURL)
        try await firstIndex.replace(
            sourceID: sourceID,
            records: [
                VectorRecord(chunk: carChunk, modelID: "test-embedding", vector: [1, 0, 0]),
                VectorRecord(chunk: fruitChunk, modelID: "test-embedding", vector: [0, 1, 0])
            ]
        )

        let reopenedIndex = SQLiteVectorIndex(databaseURL: databaseURL)
        let hits = try await reopenedIndex.search(
            vector: [0.95, 0.05, 0],
            modelID: "test-embedding",
            limit: 2
        )

        XCTAssertEqual(hits.first?.document.chunkID, carChunk.id)
        XCTAssertEqual(hits.first?.document.sourceID, sourceID)
        XCTAssertGreaterThan(hits.first?.score ?? 0, hits.last?.score ?? 0)
    }

    func testHybridRetrievalFindsSemanticMatchWithoutLexicalOverlap() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-hybrid-semantic-\(UUID().uuidString).sqlite3")
        let sparse = SQLiteKnowledgeStore(databaseURL: databaseURL)
        let vectors = SQLiteVectorIndex(databaseURL: databaseURL)
        let hybrid = HybridKnowledgeLibrary(
            sparse: sparse,
            vectors: vectors,
            embeddings: SemanticTestEmbeddingProvider()
        )

        let report = try await hybrid.ingest(
            IngestibleDocument(
                id: "automobile-note",
                title: "Engine Note",
                content: "An automobile powertrain contains an internal combustion engine.",
                sourceType: .plainText
            )
        )
        XCTAssertTrue(report.denseIndexed)

        let sparseOnly = await sparse.search("vehicle", limit: 5)
        XCTAssertTrue(sparseOnly.isEmpty, "This test requires no lexical overlap for the query term.")

        let hybridHits = await hybrid.search("vehicle", limit: 5)
        XCTAssertEqual(hybridHits.first?.document.sourceID, "automobile-note")
        XCTAssertTrue(hybridHits.first?.document.text.contains("automobile") == true)
    }

    func testReciprocalRankFusionRewardsAgreement() {
        let agreed = KnowledgeHit(
            document: KnowledgeDocument(id: "agreed", title: "Agreed", text: "shared result", chunkID: "agreed"),
            score: 1
        )
        let sparseOnly = KnowledgeHit(
            document: KnowledgeDocument(id: "sparse", title: "Sparse", text: "sparse", chunkID: "sparse"),
            score: 1
        )
        let denseOnly = KnowledgeHit(
            document: KnowledgeDocument(id: "dense", title: "Dense", text: "dense", chunkID: "dense"),
            score: 1
        )

        let fused = HybridKnowledgeLibrary.reciprocalRankFusion(
            sparse: [agreed, sparseOnly],
            dense: [agreed, denseOnly],
            limit: 3
        )

        XCTAssertEqual(fused.first?.document.chunkID, "agreed")
        XCTAssertGreaterThan(fused.first?.score ?? 0, fused.dropFirst().first?.score ?? 0)
    }

    func testHybridFallsBackToSparseWhenEmbeddingProviderFails() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-hybrid-fallback-\(UUID().uuidString).sqlite3")
        let sparse = SQLiteKnowledgeStore(databaseURL: databaseURL)
        let vectors = SQLiteVectorIndex(databaseURL: databaseURL)
        let hybrid = HybridKnowledgeLibrary(
            sparse: sparse,
            vectors: vectors,
            embeddings: FailingEmbeddingProvider()
        )

        let report = try await hybrid.ingest(
            IngestibleDocument(
                id: "torque-note",
                title: "Torque Note",
                content: "The drain plug tightening torque is 20 Nm.",
                tags: ["service"]
            )
        )

        XCTAssertFalse(report.denseIndexed)
        XCTAssertNotNil(report.denseIssue)

        let hits = await hybrid.search("drain plug torque", limit: 5)
        XCTAssertEqual(hits.first?.document.sourceID, "torque-note")
        XCTAssertTrue(hits.first?.document.text.contains("20 Nm") == true)
        let denseIssue = await hybrid.denseIssue()
        XCTAssertNotNil(denseIssue)
    }

    func testFailedReembeddingRemovesStaleDenseVectors() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-hybrid-stale-\(UUID().uuidString).sqlite3")
        let sparse = SQLiteKnowledgeStore(databaseURL: databaseURL)
        let vectors = SQLiteVectorIndex(databaseURL: databaseURL)
        let workingHybrid = HybridKnowledgeLibrary(
            sparse: sparse,
            vectors: vectors,
            embeddings: SemanticTestEmbeddingProvider()
        )

        _ = try await workingHybrid.ingest(
            IngestibleDocument(
                id: "replace-me",
                title: "Old Note",
                content: "An automobile powertrain reference."
            )
        )
        let before = try await vectors.search(
            vector: [1, 0, 0],
            modelID: "semantic-test",
            limit: 5
        )
        XCTAssertFalse(before.isEmpty)

        let failingHybrid = HybridKnowledgeLibrary(
            sparse: sparse,
            vectors: vectors,
            embeddings: FailingEmbeddingProvider(modelID: "semantic-test")
        )
        let report = try await failingHybrid.ingest(
            IngestibleDocument(
                id: "replace-me",
                title: "New Note",
                content: "A completely revised service procedure."
            )
        )
        XCTAssertFalse(report.denseIndexed)

        let after = try await vectors.search(
            vector: [1, 0, 0],
            modelID: "semantic-test",
            limit: 5
        )
        XCTAssertTrue(after.isEmpty, "Old dense vectors must not survive a failed re-embedding.")
    }

    private func makeChunk(id: String, sourceID: String, text: String) -> KnowledgeChunkRecord {
        KnowledgeChunkRecord(
            id: id,
            sourceID: sourceID,
            ordinal: 0,
            title: "Test",
            text: text,
            tags: [],
            sourceURI: "test://\(sourceID)",
            section: nil,
            contentHash: StableContentHasher().hash(text)
        )
    }
}

private struct SemanticTestEmbeddingProvider: EmbeddingProvider {
    let modelID = "semantic-test"

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            let normalized = text.lowercased()
            if normalized.contains("automobile") || normalized.contains("vehicle") || normalized.contains("car") || normalized.contains("powertrain") {
                return [1, 0, 0]
            }
            if normalized.contains("banana") || normalized.contains("fruit") {
                return [0, 1, 0]
            }
            return [0, 0, 1]
        }
    }
}

private struct FailingEmbeddingProvider: EmbeddingProvider {
    let modelID: String

    init(modelID: String = "failing-test") {
        self.modelID = modelID
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        throw EmbeddingError.invalidResponse
    }
}
