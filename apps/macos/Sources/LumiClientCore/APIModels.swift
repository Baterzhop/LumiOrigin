import Foundation

struct ChatRequestDTO: Encodable, Sendable {
    let message: String
    let conversationID: String?

    enum CodingKeys: String, CodingKey {
        case message
        case conversationID = "conversation_id"
    }
}

struct TaskCreateRequestDTO: Encodable, Sendable {
    let goal: String
    let conversationID: String?
    let maxSteps: Int
    let maxToolCalls: Int
    let maxSeconds: Int

    enum CodingKeys: String, CodingKey {
        case goal
        case conversationID = "conversation_id"
        case maxSteps = "max_steps"
        case maxToolCalls = "max_tool_calls"
        case maxSeconds = "max_seconds"
    }
}

struct MemoryCreateRequestDTO: Encodable, Sendable {
    let content: String
    let kind: String
    let title: String?
    let approvedByUser: Bool

    enum CodingKeys: String, CodingKey {
        case content, kind, title
        case approvedByUser = "approved_by_user"
    }
}

struct MemoryUpdateRequestDTO: Encodable, Sendable {
    let content: String?
    let kind: String?
    let title: String?
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
        case title, source, text, score, page, section, retrieval
    }
}

public struct MemoryHitDTO: Decodable, Sendable, Hashable, Identifiable {
    public let memoryID: String
    public let kind: String
    public let title: String?
    public let content: String
    public let source: String
    public let score: Double
    public let retrieval: [String]

    public var id: String { memoryID }

    enum CodingKeys: String, CodingKey {
        case memoryID = "memory_id"
        case kind, title, content, source, score, retrieval
    }
}

public struct MemoryRecordDTO: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: String
    public let title: String?
    public let content: String
    public let source: String
    public let approved: Bool
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, title, content, source, approved
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct MemoriesResponse: Decodable, Sendable {
    public let memories: [MemoryRecordDTO]
}

public struct MemoryEnvelopeResponse: Decodable, Sendable {
    public let memory: MemoryRecordDTO
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
    public let memories: [MemoryHitDTO]?

    enum CodingKeys: String, CodingKey {
        case type
        case generationID = "generation_id"
        case conversationID = "conversation_id"
        case delta, content
        case messageID = "message_id"
        case provider, model, fallback, error
        case finishReason = "finish_reason"
        case citations, memories
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

public struct RuntimeToolsStatus: Decodable, Sendable {
    public let count: Int
    public let workspace: String
    public let criticalEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case count, workspace
        case criticalEnabled = "critical_enabled"
    }
}

public struct RuntimeMemoryStatus: Decodable, Sendable {
    public let count: Int
    public let semanticEnabled: Bool
    public let embeddingModel: String?
    public let recallK: Int
    public let contextMaxInputTokens: Int
    public let contextRecentTokens: Int

    enum CodingKeys: String, CodingKey {
        case count
        case semanticEnabled = "semantic_enabled"
        case embeddingModel = "embedding_model"
        case recallK = "recall_k"
        case contextMaxInputTokens = "context_max_input_tokens"
        case contextRecentTokens = "context_recent_tokens"
    }
}

public struct RuntimeStatusResponse: Decodable, Sendable {
    public let ok: Bool
    public let streaming: Bool
    public let provider: String
    public let model: String
    public let activeGenerations: Int
    public let rag: RuntimeRAGStatus?
    public let tools: RuntimeToolsStatus?
    public let memory: RuntimeMemoryStatus?

    enum CodingKeys: String, CodingKey {
        case ok, streaming, provider, model
        case activeGenerations = "active_generations"
        case rag, tools, memory
    }
}

public struct ToolCallDTO: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let taskID: String
    public let toolName: String
    public let risk: String
    public let status: String
    public let decisionReason: String?
    public let error: String?
    public let argumentsPreview: String?
    public let resultPreview: String?
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case toolName = "tool_name"
        case risk, status
        case decisionReason = "decision_reason"
        case error
        case argumentsPreview = "arguments_preview"
        case resultPreview = "result_preview"
        case createdAt = "created_at"
    }
}

public struct AgentTaskDTO: Decodable, Sendable, Identifiable {
    public let id: String
    public let conversationID: String?
    public let goal: String
    public let status: String
    public let stepCount: Int
    public let maxSteps: Int
    public let maxToolCalls: Int
    public let deadlineAt: String?
    public let resultText: String?
    public let error: String?
    public let waitingToolCallID: String?
    public let toolCalls: [ToolCallDTO]

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case goal, status
        case stepCount = "step_count"
        case maxSteps = "max_steps"
        case maxToolCalls = "max_tool_calls"
        case deadlineAt = "deadline_at"
        case resultText = "result_text"
        case error
        case waitingToolCallID = "waiting_tool_call_id"
        case toolCalls = "tool_calls"
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
