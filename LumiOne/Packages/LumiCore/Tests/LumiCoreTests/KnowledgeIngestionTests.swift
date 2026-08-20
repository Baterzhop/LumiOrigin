import Foundation
import XCTest
@testable import LumiCore

final class KnowledgeIngestionTests: XCTestCase {
    func testChunkingIsBoundedDeterministicAndPreservesPageProvenance() throws {
        let resourceID = UserFileResourceID(rawValue: "document-1")
        let extracted = ExtractedDocument(
            sourceResourceID: resourceID,
            displayName: "manual.pdf",
            mediaType: "application/pdf",
            pages: [
                ExtractedDocumentPage(
                    pageNumber: 1,
                    text: Array(repeating: "page-one-word", count: 35).joined(separator: " ")
                ),
                ExtractedDocumentPage(
                    pageNumber: 2,
                    text: Array(repeating: "page-two-word", count: 35).joined(separator: " ")
                )
            ]
        )
        let configuration = try KnowledgeChunker.Configuration(
            maxCharacters: 256,
            overlapCharacters: 32
        )
        let chunker = KnowledgeChunker(configuration: configuration)
        let documentID = UUID()

        let first = try chunker.chunk(extracted, documentID: documentID)
        let second = try chunker.chunk(extracted, documentID: documentID)

        XCTAssertGreaterThan(first.count, 2)
        XCTAssertEqual(first.map(\.ordinal), Array(0..<first.count))
        XCTAssertTrue(first.allSatisfy { $0.text.count <= 256 })
        XCTAssertTrue(first.allSatisfy { $0.pageStart >= 1 && $0.pageEnd <= 2 })
        XCTAssertTrue(first.allSatisfy { $0.pageStart <= $0.pageEnd })

        XCTAssertEqual(first.map(\.text), second.map(\.text))
        XCTAssertEqual(first.map(\.pageStart), second.map(\.pageStart))
        XCTAssertEqual(first.map(\.pageEnd), second.map(\.pageEnd))
    }

    func testReingestReusesDocumentIdentityAndReplacesOldChunks() async throws {
        let fixture = try KnowledgeDatabaseFixture()
        defer { fixture.cleanup() }

        let resourceID = UserFileResourceID(rawValue: "stable-source")
        let store = try SQLiteKnowledgeStore(url: fixture.databaseURL)

        let firstEngine = KnowledgeIngestionEngine(
            extractor: StaticDocumentExtractor(
                document: makeDocument(
                    resourceID: resourceID,
                    displayName: "guide.pdf",
                    pages: ["alpha original knowledge text"]
                )
            ),
            store: store
        )
        let first = try await firstEngine.ingest(resourceID: resourceID)

        let secondEngine = KnowledgeIngestionEngine(
            extractor: StaticDocumentExtractor(
                document: makeDocument(
                    resourceID: resourceID,
                    displayName: "guide.pdf",
                    pages: ["beta replacement knowledge text"]
                )
            ),
            store: store
        )
        let second = try await secondEngine.ingest(resourceID: resourceID)

        XCTAssertEqual(first.document.id, second.document.id)
        XCTAssertEqual(first.document.createdAt, second.document.createdAt)

        let documents = try await store.listDocuments()
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.sourceResourceID, resourceID)

        let chunks = try await store.loadChunks(documentID: second.document.id)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.text.contains("beta") })
        XCTAssertFalse(chunks.contains { $0.text.contains("alpha") })
    }

    func testKnowledgeSurvivesStoreReopen() async throws {
        let fixture = try KnowledgeDatabaseFixture()
        defer { fixture.cleanup() }

        let resourceID = UserFileResourceID(rawValue: "durable-source")
        let firstStore = try SQLiteKnowledgeStore(url: fixture.databaseURL)
        let engine = KnowledgeIngestionEngine(
            extractor: StaticDocumentExtractor(
                document: makeDocument(
                    resourceID: resourceID,
                    displayName: "durable.pdf",
                    pages: ["first page text", "second page durable text"]
                )
            ),
            store: firstStore
        )
        let ingested = try await engine.ingest(resourceID: resourceID)

        let reopened = try SQLiteKnowledgeStore(url: fixture.databaseURL)
        let restored = try await reopened.loadDocument(sourceResourceID: resourceID)
        let restoredDocument = try XCTUnwrap(restored)
        XCTAssertEqual(restoredDocument.id, ingested.document.id)
        XCTAssertEqual(restoredDocument.displayName, "durable.pdf")
        XCTAssertEqual(restoredDocument.pageCount, 2)

        let chunks = try await reopened.loadChunks(documentID: restoredDocument.id)
        XCTAssertEqual(chunks.map(\.text), ingested.chunks.map(\.text))
        XCTAssertEqual(chunks.map(\.pageStart), ingested.chunks.map(\.pageStart))
        XCTAssertEqual(chunks.map(\.pageEnd), ingested.chunks.map(\.pageEnd))
    }

    func testFailedExtractionDoesNotReplaceExistingKnowledge() async throws {
        let fixture = try KnowledgeDatabaseFixture()
        defer { fixture.cleanup() }

        let resourceID = UserFileResourceID(rawValue: "protected-existing")
        let store = try SQLiteKnowledgeStore(url: fixture.databaseURL)
        let goodEngine = KnowledgeIngestionEngine(
            extractor: StaticDocumentExtractor(
                document: makeDocument(
                    resourceID: resourceID,
                    displayName: "existing.pdf",
                    pages: ["existing safe knowledge"]
                )
            ),
            store: store
        )
        let original = try await goodEngine.ingest(resourceID: resourceID)

        let failing = KnowledgeIngestionEngine(
            extractor: FailingDocumentExtractor(),
            store: store
        )
        do {
            _ = try await failing.ingest(resourceID: resourceID)
            XCTFail("Extraction failure must propagate")
        } catch let error as DocumentExtractionError {
            XCTAssertEqual(error, .invalidDocument("broken.pdf"))
        }

        let restored = try await store.loadDocument(sourceResourceID: resourceID)
        XCTAssertEqual(restored?.id, original.document.id)
        let chunks = try await store.loadChunks(documentID: original.document.id)
        XCTAssertEqual(chunks.map(\.text), original.chunks.map(\.text))
    }

    func testExtractorCannotSubstituteAnotherResourceIdentity() async throws {
        let fixture = try KnowledgeDatabaseFixture()
        defer { fixture.cleanup() }

        let requested = UserFileResourceID(rawValue: "requested")
        let returned = UserFileResourceID(rawValue: "different")
        let store = try SQLiteKnowledgeStore(url: fixture.databaseURL)
        let engine = KnowledgeIngestionEngine(
            extractor: StaticDocumentExtractor(
                document: makeDocument(
                    resourceID: returned,
                    displayName: "wrong.pdf",
                    pages: ["wrong source"]
                )
            ),
            store: store
        )

        do {
            _ = try await engine.ingest(resourceID: requested)
            XCTFail("Extractor source substitution must fail closed")
        } catch let error as KnowledgeIngestionError {
            XCTAssertEqual(error, .sourceIdentityMismatch)
        }

        XCTAssertTrue(try await store.listDocuments().isEmpty)
    }

    func testImageOnlyOrBlankExtractionProducesNoKnowledge() async throws {
        let fixture = try KnowledgeDatabaseFixture()
        defer { fixture.cleanup() }

        let resourceID = UserFileResourceID(rawValue: "blank")
        let store = try SQLiteKnowledgeStore(url: fixture.databaseURL)
        let engine = KnowledgeIngestionEngine(
            extractor: StaticDocumentExtractor(
                document: makeDocument(
                    resourceID: resourceID,
                    displayName: "blank.pdf",
                    pages: ["   \n\n ", "\t"]
                )
            ),
            store: store
        )

        do {
            _ = try await engine.ingest(resourceID: resourceID)
            XCTFail("Blank extracted text must not be indexed")
        } catch let error as KnowledgeIngestionError {
            XCTAssertEqual(error, .noChunks)
        }
        XCTAssertTrue(try await store.listDocuments().isEmpty)
    }

    func testSQLiteReplacementRollsBackIfChunkInsertFailsMidTransaction() async throws {
        let fixture = try KnowledgeDatabaseFixture()
        defer { fixture.cleanup() }

        let resourceID = UserFileResourceID(rawValue: "rollback-source")
        let store = try SQLiteKnowledgeStore(url: fixture.databaseURL)
        let originalDocument = KnowledgeDocument(
            sourceResourceID: resourceID,
            displayName: "original.pdf",
            mediaType: "application/pdf",
            pageCount: 1,
            metadata: ["revision": .string("original")]
        )
        let originalChunk = KnowledgeChunk(
            documentID: originalDocument.id,
            ordinal: 0,
            pageStart: 1,
            pageEnd: 1,
            text: "original durable chunk"
        )
        try await store.replaceDocument(originalDocument, chunks: [originalChunk])

        let replacement = KnowledgeDocument(
            id: originalDocument.id,
            sourceResourceID: resourceID,
            displayName: "replacement.pdf",
            mediaType: "application/pdf",
            pageCount: 1,
            metadata: ["revision": .string("replacement")],
            createdAt: originalDocument.createdAt,
            updatedAt: Date()
        )
        let duplicateChunkID = UUID()
        let invalidChunks = [
            KnowledgeChunk(
                id: duplicateChunkID,
                documentID: replacement.id,
                ordinal: 0,
                pageStart: 1,
                pageEnd: 1,
                text: "replacement first"
            ),
            KnowledgeChunk(
                id: duplicateChunkID,
                documentID: replacement.id,
                ordinal: 1,
                pageStart: 1,
                pageEnd: 1,
                text: "replacement second"
            )
        ]

        do {
            try await store.replaceDocument(replacement, chunks: invalidChunks)
            XCTFail("Duplicate chunk primary key should fail inside the transaction")
        } catch {
            // Expected SQLite constraint failure after replacement has begun.
        }

        let restored = try await store.loadDocument(sourceResourceID: resourceID)
        XCTAssertEqual(restored?.displayName, "original.pdf")
        XCTAssertEqual(restored?.metadata["revision"], .string("original"))

        let restoredChunks = try await store.loadChunks(documentID: originalDocument.id)
        XCTAssertEqual(restoredChunks.count, 1)
        XCTAssertEqual(restoredChunks.first?.text, "original durable chunk")
    }

    private func makeDocument(
        resourceID: UserFileResourceID,
        displayName: String,
        pages: [String]
    ) -> ExtractedDocument {
        ExtractedDocument(
            sourceResourceID: resourceID,
            displayName: displayName,
            mediaType: "application/pdf",
            pages: pages.enumerated().map {
                ExtractedDocumentPage(pageNumber: $0.offset + 1, text: $0.element)
            },
            metadata: ["extractor": .string("test")]
        )
    }
}

private struct StaticDocumentExtractor: DocumentTextExtractor, Sendable {
    let document: ExtractedDocument

    func extract(resourceID: UserFileResourceID) async throws -> ExtractedDocument {
        document
    }
}

private struct FailingDocumentExtractor: DocumentTextExtractor, Sendable {
    func extract(resourceID: UserFileResourceID) async throws -> ExtractedDocument {
        throw DocumentExtractionError.invalidDocument("broken.pdf")
    }
}

private final class KnowledgeDatabaseFixture {
    let root: URL
    let databaseURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiKnowledgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("knowledge.sqlite3")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
