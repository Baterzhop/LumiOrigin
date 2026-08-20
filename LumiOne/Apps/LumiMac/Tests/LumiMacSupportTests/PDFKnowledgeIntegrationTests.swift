import CoreGraphics
import CoreText
import Foundation
import XCTest
import LumiCore
@testable import LumiMacSupport

final class PDFKnowledgeIntegrationTests: XCTestCase {
    func testSelectedPDFIngestsIntoDurableKnowledgeAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiPDFKnowledge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfURL = root.appendingPathComponent("knowledge-source.pdf")
        try makeIntegrationPDF(
            at: pdfURL,
            pageTexts: [
                "First PDF knowledge page with provenance alpha.",
                "Second PDF knowledge page with provenance beta."
            ]
        )

        let catalog = try SecurityScopedFileCatalog(
            storeURL: root.appendingPathComponent("catalog.json")
        )
        let source = try catalog.register(url: pdfURL)
        let storeURL = root.appendingPathComponent("knowledge.sqlite3")
        let store = try SQLiteKnowledgeStore(url: storeURL)
        let engine = KnowledgeIngestionEngine(
            extractor: PDFKitDocumentExtractor(catalog: catalog),
            store: store
        )

        let result = try await engine.ingest(resourceID: source.id)
        XCTAssertEqual(result.document.sourceResourceID, source.id)
        XCTAssertEqual(result.document.displayName, "knowledge-source.pdf")
        XCTAssertEqual(result.document.pageCount, 2)
        XCTAssertFalse(result.chunks.isEmpty)
        XCTAssertTrue(result.chunks.allSatisfy { $0.pageStart >= 1 && $0.pageEnd <= 2 })
        XCTAssertTrue(result.chunks.contains { $0.text.contains("alpha") })
        XCTAssertTrue(result.chunks.contains { $0.text.contains("beta") })

        let reopened = try SQLiteKnowledgeStore(url: storeURL)
        let persisted = try await reopened.loadDocument(sourceResourceID: source.id)
        let persistedDocument = try XCTUnwrap(persisted)
        XCTAssertEqual(persistedDocument.id, result.document.id)
        XCTAssertEqual(persistedDocument.metadata["extractor"], .string("PDFKit"))

        let persistedChunks = try await reopened.loadChunks(documentID: persistedDocument.id)
        XCTAssertEqual(persistedChunks.map(\.text), result.chunks.map(\.text))
        XCTAssertEqual(persistedChunks.map(\.pageStart), result.chunks.map(\.pageStart))
        XCTAssertEqual(persistedChunks.map(\.pageEnd), result.chunks.map(\.pageEnd))
    }

    private func makeIntegrationPDF(at url: URL, pageTexts: [String]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard
            let consumer = CGDataConsumer(url: url as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw PDFKnowledgeTestError.couldNotCreateContext
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for pageText in pageTexts {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: pageText,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}

private enum PDFKnowledgeTestError: Error {
    case couldNotCreateContext
}
