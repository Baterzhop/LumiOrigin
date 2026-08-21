#if canImport(SwiftUI)
import Foundation
import SwiftUI
import LumiCore
#if canImport(PDFKit)
import PDFKit
#endif

struct KnowledgeFileLoader: Sendable {
    enum LoaderError: Error, LocalizedError {
        case fileTooLarge(Int64)
        case unsupportedType(String)
        case unreadableText
        case invalidPDF
        case pdfHasNoText

        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let bytes):
                return "The selected file is too large to import safely (\(bytes) bytes)."
            case .unsupportedType(let type):
                return "Unsupported knowledge file type: \(type)."
            case .unreadableText:
                return "The selected text file could not be decoded as UTF-8 or UTF-16."
            case .invalidPDF:
                return "The selected PDF could not be opened."
            case .pdfHasNoText:
                return "The PDF has no extractable text layer. Scanned-image OCR is not enabled in this phase."
            }
        }
    }

    static let maximumFileBytes: Int64 = 50 * 1_024 * 1_024

    static func load(url: URL) async throws -> IngestibleDocument {
        try await Task.detached(priority: .userInitiated) {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == false {
                throw LoaderError.unsupportedType("not a regular file")
            }
            if let fileSize = values.fileSize, Int64(fileSize) > maximumFileBytes {
                throw LoaderError.fileTooLarge(Int64(fileSize))
            }

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            if Int64(data.count) > maximumFileBytes {
                throw LoaderError.fileTooLarge(Int64(data.count))
            }

            let ext = url.pathExtension.lowercased()
            let sourceType: KnowledgeSourceType
            let content: String

            switch ext {
            case "txt", "text":
                sourceType = .plainText
                content = try decodeText(data)

            case "md", "markdown":
                sourceType = .markdown
                content = try decodeText(data)

            case "pdf":
                sourceType = .pdf
                content = try extractPDFText(data)

            default:
                throw LoaderError.unsupportedType(ext.isEmpty ? "unknown" : ext)
            }

            let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                throw sourceType == .pdf ? LoaderError.pdfHasNoText : LoaderError.unreadableText
            }

            let stablePath = url.standardizedFileURL.path
            let sourceID = "file-" + StableContentHasher().hash(stablePath)
            let title = url.deletingPathExtension().lastPathComponent

            return IngestibleDocument(
                id: sourceID,
                title: title.isEmpty ? url.lastPathComponent : title,
                content: content,
                sourceType: sourceType,
                sourceURI: url.absoluteString,
                tags: ["imported", sourceType.rawValue]
            )
        }.value
    }

    private static func decodeText(_ data: Data) throws -> String {
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: .utf16) { return value }
        if let value = String(data: data, encoding: .utf16LittleEndian) { return value }
        if let value = String(data: data, encoding: .utf16BigEndian) { return value }
        throw LoaderError.unreadableText
    }

    private static func extractPDFText(_ data: Data) throws -> String {
#if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else {
            throw LoaderError.invalidPDF
        }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)

        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let joined = pages.joined(separator: "\u{000C}")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LoaderError.pdfHasNoText
        }
        return joined
#else
        throw LoaderError.unsupportedType("pdf")
#endif
    }
}
#endif
