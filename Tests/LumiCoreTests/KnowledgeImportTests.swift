import XCTest
@testable import LumiCore

final class KnowledgeImportTests: XCTestCase {
    func testSQLiteKnowledgeSourceCatalogListsReimportsAndRemovesSources() async throws {
        let databaseURL = temporaryDatabase("source-catalog")
        let store = SQLiteKnowledgeStore(databaseURL: databaseURL)
        let ingestor = DocumentIngestor()

        _ = try await ingestor.ingest(
            IngestibleDocument(
                id: "manual-a",
                title: "Manual A",
                content: "Initial torque specification is twenty newton metres.",
                sourceType: .plainText,
                sourceURI: "file:///manual-a.txt"
            ),
            into: store
        )
        _ = try await ingestor.ingest(
            IngestibleDocument(
                id: "manual-b",
                title: "Manual B",
                content: "Suspension preload setup notes.",
                sourceType: .markdown,
                sourceURI: "file:///manual-b.md"
            ),
            into: store
        )

        var sources = try await store.listSources(limit: 10)
        XCTAssertEqual(Set(sources.map(\.id)), Set(["manual-a", "manual-b"]))

        _ = try await ingestor.ingest(
            IngestibleDocument(
                id: "manual-a",
                title: "Manual A revised",
                content: "Revised drain plug torque specification is 20 Nm.",
                sourceType: .plainText,
                sourceURI: "file:///manual-a.txt",
                updatedAt: Date(timeIntervalSinceNow: 60)
            ),
            into: store
        )

        sources = try await store.listSources(limit: 10)
        XCTAssertEqual(sources.count, 2, "Re-import with a stable source ID must replace, not duplicate, the source.")
        XCTAssertEqual(sources.first(where: { $0.id == "manual-a" })?.title, "Manual A revised")

        let oldHits = await store.search("twenty newton metres", limit: 5)
        XCTAssertTrue(oldHits.isEmpty, "Sparse index must not retain stale chunks after re-import.")
        let revisedHits = await store.search("drain plug torque", limit: 5)
        XCTAssertEqual(revisedHits.first?.document.sourceID, "manual-a")

        try await store.removeSource(id: "manual-a")
        let remaining = try await store.listSources(limit: 10)
        XCTAssertEqual(remaining.map(\.id), ["manual-b"])
        XCTAssertTrue(await store.search("drain plug torque", limit: 5).isEmpty)
    }

    func testEngineManagedKnowledgeUsesSameHybridRetrieverAndRemovesDenseVectors() async throws {
        let databaseURL = temporaryDatabase("engine-managed-library")
        let sparse = SQLiteKnowledgeStore(databaseURL: databaseURL)
        let vectors = SQLiteVectorIndex(databaseURL: databaseURL)
        let hybrid = HybridKnowledgeLibrary(
            sparse: sparse,
            vectors: vectors,
            embeddings: ImportEmbeddingProvider()
        )
        let engine = LumiEngine(
            llm: LocalFallbackClient(),
            knowledge: hybrid
        )

        let report = try await engine.ingestKnowledge(
            IngestibleDocument(
                id: "vehicle-source",
                title: "Vehicle Source",
                content: "An automobile powertrain contains an engine.",
                tags: ["vehicle"]
            )
        )
        XCTAssertTrue(report.denseIndexed)
        XCTAssertEqual(try await engine.knowledgeSources(limit: 10).map(\.id), ["vehicle-source"])

        let hits = await engine.knowledge.search("vehicle", limit: 5)
        XCTAssertEqual(hits.first?.document.sourceID, "vehicle-source")

        let denseBefore = try await vectors.search(
            vector: [1, 0, 0],
            modelID: "import-test",
            limit: 5
        )
        XCTAssertFalse(denseBefore.isEmpty)

        try await engine.removeKnowledgeSource(id: "vehicle-source")
        XCTAssertTrue(try await engine.knowledgeSources(limit: 10).isEmpty)
        let denseAfter = try await vectors.search(
            vector: [1, 0, 0],
            modelID: "import-test",
            limit: 5
        )
        XCTAssertTrue(denseAfter.isEmpty)
    }

    func testPDFFormFeedPagesPreservePageNumbersInChunksAndSearchHits() async throws {
        let databaseURL = temporaryDatabase("pdf-pages")
        let store = SQLiteKnowledgeStore(databaseURL: databaseURL)
        let content = "Cover page with general introduction.\u{000C}Drain plug torque is 20 Nm on this service page.\u{000C}Final notes."
        let document = IngestibleDocument(
            id: "pdf-manual",
            title: "Workshop Manual",
            content: content,
            sourceType: .pdf,
            sourceURI: "file:///workshop.pdf"
        )

        _ = try await DocumentIngestor().ingest(document, into: store)
        let hits = await store.search("drain plug torque", limit: 5)

        XCTAssertEqual(hits.first?.document.sourceID, "pdf-manual")
        XCTAssertEqual(hits.first?.document.page, 2)
        XCTAssertEqual(hits.first?.document.sourceURI, "file:///workshop.pdf")
    }

    func testEngineRejectsManagedKnowledgeOperationsWhenRetrieverIsReadOnly() async {
        let engine = LumiEngine(
            llm: LocalFallbackClient(),
            knowledge: KnowledgeIndex()
        )

        do {
            _ = try await engine.ingestKnowledge(
                IngestibleDocument(title: "Unavailable", content: "content")
            )
            XCTFail("Expected a read-only retriever to reject managed ingestion.")
        } catch let error as KnowledgeLibraryError {
            guard case .unavailable = error else {
                return XCTFail("Unexpected knowledge-library error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func temporaryDatabase(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-\(prefix)-\(UUID().uuidString).sqlite3")
    }
}

private struct ImportEmbeddingProvider: EmbeddingProvider {
    let modelID = "import-test"

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            let normalized = text.lowercased()
            if normalized.contains("automobile") || normalized.contains("vehicle") || normalized.contains("powertrain") {
                return [1, 0, 0]
            }
            return [0, 1, 0]
        }
    }
}
