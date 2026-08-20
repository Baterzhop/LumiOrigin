import Foundation

struct ChatRequestDTO: Encodable, Sendable {
    let message: String
    let conversationID: String?

    enum CodingKeys: String, CodingKey {
        case message
        case conversationID = "conversation_id"
    }
}

public struct CitationDTO: Decodable, Sendable, Hashable, Identifiable {
    public let chunkID: String
    public let documentID: String
    public let title: String?
    public let source: String?
    public let text: String
    public let score: Double
    public let page: Int?
    public let section: String?
    public let retrieval: [String]

    public var id: String { chunkID }

    enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case documentID = "document_id"
        case title
        case source
        case text
        case score
        case page
        case section
        case retrieval
    }
}

public enum StreamEventType: String, Decodable, Sendable {
    case started
    case delta
    case completed
    case cancelled
    case error
}

public struct ChatStreamEvent: Decodable, Sendable {
    public let type: StreamEventType
    public let generationID: String
    public let conversationID: String
    public let delta: String?
    public let content: String?
    public let messageID: String?
    public let provider: String?
    public let model: String?
    public let fallback: Bool?
    public let error: String?
    public let finishReason: String?
    public let citations: [CitationDTO]?

    enum CodingKeys: String, CodingKey {
        case type
        case generationID = "generation_id"
        case conversationID = "conversation_id"
        case delta
        case content
        case messageID = "message_id"
        case provider
        case model
        case fallback
        case error
        case finishReason = "finish_reason"
        case citations
    }
}

public struct HealthResponse: Decodable, Sendable {
    public let ok: Bool
    public let service: String
    public let version: String
}

public struct RuntimeRAGStatus: Decodable, Sendable {
    public let sparse: String
    public let denseEnabled: Bool
    public let embeddingModel: String?
    public let rerankerModel: String?

    enum CodingKeys: String, CodingKey {
        case sparse
        case denseEnabled = "dense_enabled"
        case embeddingModel = "embedding_model"
        case rerankerModel = "reranker_model"
    }
}

public struct RuntimeStatusResponse: Decodable, Sendable {
    public let ok: Bool
    public let streaming: Bool
    public let provider: String
    public let model: String
    public let activeGenerations: Int
    public let rag: RuntimeRAGStatus?

    enum CodingKeys: String, CodingKey {
        case ok
        case streaming
        case provider
        case model
        case activeGenerations = "active_generations"
        case rag
    }
}

public struct KnowledgeDocumentDTO: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let source: String
    public let title: String?
    public let contentHash: String
    public let language: String?
    public let mimeType: String?
    public let createdAt: String
    public let updatedAt: String
    public let chunkCount: Int

    enum CodingKeys: String, CodingKey {
        case id, source, title, language
        case contentHash = "content_hash"
        case mimeType = "mime_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case chunkCount = "chunk_count"
    }
}

public struct KnowledgeDocumentsResponse: Decodable, Sendable {
    public let documents: [KnowledgeDocumentDTO]
}

public struct KnowledgeUploadResponse: Decodable, Sendable {
    public let documentID: String
    public let title: String
    public let source: String
    public let mimeType: String
    public let chunkCount: Int
    public let deduplicated: Bool
    public let embeddingModel: String?
    public let embeddedChunks: Int
    public let embeddingError: String?

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case title, source
        case mimeType = "mime_type"
        case chunkCount = "chunk_count"
        case deduplicated
        case embeddingModel = "embedding_model"
        case embeddedChunks = "embedded_chunks"
        case embeddingError = "embedding_error"
    }
}
