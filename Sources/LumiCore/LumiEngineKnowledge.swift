import Foundation

public enum KnowledgeLibraryError: Error, LocalizedError, Sendable {
    case unavailable
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The configured knowledge retriever does not support ingestion or source management."
        case .emptyDocument:
            return "The imported knowledge document contains no text."
        }
    }
}

public extension LumiEngine {
    @discardableResult
    func ingestKnowledge(_ document: IngestibleDocument) async throws -> HybridIngestionReport {
        guard let library = knowledge as? any KnowledgeLibraryManaging else {
            throw KnowledgeLibraryError.unavailable
        }
        guard !document.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeLibraryError.emptyDocument
        }
        return try await library.ingest(document)
    }

    func knowledgeSources(limit: Int = 100) async throws -> [KnowledgeSourceRecord] {
        guard let library = knowledge as? any KnowledgeLibraryManaging else {
            throw KnowledgeLibraryError.unavailable
        }
        return try await library.listSources(limit: max(0, min(limit, 1_000)))
    }

    func removeKnowledgeSource(id: String) async throws {
        guard let library = knowledge as? any KnowledgeLibraryManaging else {
            throw KnowledgeLibraryError.unavailable
        }
        try await library.removeSource(id: id)
    }
}
