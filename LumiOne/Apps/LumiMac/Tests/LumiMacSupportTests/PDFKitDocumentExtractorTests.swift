import CoreGraphics
import CoreText
import Foundation
import XCTest
import LumiCore
@testable import LumiMacSupport

final class PDFKitDocumentExtractorTests: XCTestCase {
    func testPDFExtractionPreservesPagesAndOpaqueSourceIdentity() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.cleanup() }

        let pdfURL = fixture.root.appendingPathComponent("manual.pdf")
        try makePDF(
            at: pdfURL,
            pageTexts: [
                "Lumi PDF page one provenance",
                "Lumi PDF page two durable knowledge"
            ]
        )

        let catalog = try SecurityScopedFileCatalog(storeURL: fixture.catalogURL)
        let descriptor = try catalog.register(url: pdfURL)
        let extractor = PDFKitDocumentExtractor(catalog: catalog)

        let document = try await extractor.extract(resourceID: descriptor.id)
        XCTAssertEqual(document.sourceResourceID, descriptor.id)
        XCTAssertEqual(document.displayName, "manual.pdf")
        XCTAssertEqual(document.mediaType, "application/pdf")
        XCTAssertEqual(document.pages.map(\.pageNumber), [1, 2])
        XCTAssertTrue(document.pages[0].text.contains("page one provenance"))
        XCTAssertTrue(document.pages[1].text.contains("page two durable knowledge"))
        XCTAssertEqual(document.metadata["extractor"], .string("PDFKit"))
        XCTAssertEqual(document.metadata["pageCount"], .number(2))
    }

    func testNonPDFRegisteredResourceFailsAsUnsupported() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.cleanup() }

        let textURL = fixture.root.appendingPathComponent("notes.txt")
        try Data("plain text".utf8).write(to: textURL)

        let catalog = try SecurityScopedFileCatalog(storeURL: fixture.catalogURL)
        let descriptor = try catalog.register(url: textURL)
        let extractor = PDFKitDocumentExtractor(catalog: catalog)

        do {
            _ = try await extractor.extract(resourceID: descriptor.id)
            XCTFail("Non-PDF resources must not be parsed through PDFKit")
        } catch let error as DocumentExtractionError {
            XCTAssertEqual(error, .unsupportedResource("notes.txt"))
        }
    }

    func testBlankPDFIsReportedAsNoExtractableText() async throws {
        let fixture = try PDFExtractionFixture()
        defer { fixture.cleanup() }

        let pdfURL = fixture.root.appendingPathComponent("blank.pdf")
        try makePDF(at: pdfURL, pageTexts: [nil, nil])

        let catalog = try SecurityScopedFileCatalog(storeURL: fixture.catalogURL)
        let descriptor = try catalog.register(url: pdfURL)
        let extractor = PDFKitDocumentExtractor(catalog: catalog)

        do {
            _ = try await extractor.extract(resourceID: descriptor.id)
            XCTFail("Image-only/blank PDFs need an explicit no-text outcome")
        } catch let error as DocumentExtractionError {
            XCTAssertEqual(error, .noExtractableText("blank.pdf"))
        }
    }

    private func makePDF(at url: URL, pageTexts: [String?]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard
            let consumer = CGDataConsumer(url: url as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw PDFTestError.couldNotCreateContext
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)

        for pageText in pageTexts {
            context.beginPDFPage(nil)

            if let pageText {
                let attributed = NSAttributedString(
                    string: pageText,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font
                    ]
                )
                let line = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(line, context)
            }

            context.endPDFPage()
        }

        context.closePDF()
    }
}

private final class PDFExtractionFixture {
    let root: URL
    let catalogURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiPDFKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        catalogURL = root.appendingPathComponent("catalog.json")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum PDFTestError: Error {
    case couldNotCreateContext
}
